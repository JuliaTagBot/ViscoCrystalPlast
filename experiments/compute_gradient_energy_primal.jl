using ViscoCrystalPlast
using JuAFEM
using ForwardDiff
using ContMechTensors
using TimerOutputs
using DataFrames
using JLD
using FileIO


import ViscoCrystalPlast: GeometryMesh, Dofs, DirichletBoundaryConditions, CrystPlastMP, QuadratureData, DofHandler
import ViscoCrystalPlast: add_dofs, dofs_element, element_coordinates, move_quadrature_data_to_nodes, interpolate_to
import ViscoCrystalPlast: element_set, node_set, element_vertices

import ViscoCrystalPlast: add_field!, close!, element_set, element_coordinates,
                            add_dirichletbc!, ndim, ndofs, nelements, nnodes, free_dofs, update_dirichletbcs!, apply!,
                                create_lookup, add_element_set!, add_node_set!

const VP = ViscoCrystalPlast
function get_RVE_boundary_nodes(mesh::GeometryMesh)
    nodes_on_RVE_edge = Int[]

    for (name, nodes) in mesh.node_sets
        if contains(name, "body")
            continue
        end
        append!(nodes_on_RVE_edge, nodes)
    end

    return unique(nodes_on_RVE_edge)
end

function make_slip_boundary_nodeset!(mesh::GeometryMesh)
    nodes_grain = [Int[] for i in 1:length(mesh.element_sets)]
    curr_set = 0
    for (name, elements) in mesh.element_sets
        curr_set += 1
        for element in elements
            for v in element_vertices(mesh, element)
                push!(nodes_grain[curr_set], v)
            end
        end
    end
    nodes_grain = [unique(x) for x in nodes_grain]

    n_grains = zeros(Int, nnodes(mesh))
    for (i, nodes_in_grain) in enumerate(nodes_grain)
        for node in nodes_in_grain
            n_grains[node] += 1
        end
    end

    nodes_in_boundary = find(x -> x > 1, n_grains)

    # RVE boundary also need bcs
    append!(nodes_in_boundary, get_RVE_boundary_nodes(mesh))

    add_node_set!(mesh, "slip_boundary", unique(nodes_in_boundary))

    return nodes_in_boundary
end

function create_element_to_grain_map{dim}(mesh::GeometryMesh{dim})
    if dim == 2
        grain_name = "face"
    else
        grain_name = "poly"
    end
    poly = zeros(Int, nelements(mesh))
    for (name, elements) in mesh.element_sets
        if !startswith(name, grain_name)
            continue
        else
            p = parse(Int, name[5:end])
            for element in elements
                poly[element] = p
            end
        end
    end
    return poly
end

const dim = 3

function startit{dim}(::Type{Dim{dim}})


    df = DataFrame(n_elements = Int[], l = Float64[], tot_slip = Float64[], tot_grad_energy = Float64[], tot_elastic_energy = Float64[],
                     err_slip = Float64[], err_grad_energy = Float64[], err_elastic_energy = Float64[])

    df_l_study = DataFrame(l = Float64[], tot_slip = Float64[], tot_grad_energy = Float64[], tot_elast_en = Float64[])

    function_space = Lagrange{dim, RefTetrahedron, 1}()
    quad_rule = QuadratureRule(Dim{dim}, RefTetrahedron(), 1)
    fe_values = FEValues(Float64, quad_rule, function_space)

    primal_problem = ViscoCrystalPlast.PrimalProblem(dim, function_space)

    write_dataframe = true

    for l in 0.1:0.1
        #if dim == 2
        #    mp = setup_material(Dim{dim}, l)
        #else
        #    mp = setup_material_3d(Dim{dim}, l)
        #end
        times = linspace(0.0, 10.0, 2)

        ############################
        # Solve fine scale problem #

        ############################
        m = load("/home/kristoffer/neper-neutral/build/n10-id1.inp")
        mesh_fine = VP.GeometryMesh(m, "C3D4")
        add_node_set!(mesh_fine, "RVE_boundary", get_RVE_boundary_nodes(mesh_fine))
        make_slip_boundary_nodeset!(mesh_fine)
        polys = create_element_to_grain_map(mesh_fine)

        mps = [setup_material_3d(Dim{3}, 0.2) for i in 1:length(unique(polys))]

        dh = DofHandler(mesh_fine)
        VP.add_field!(dh, [:u, :γ1, :γ2], (dim, 1, 1))
        close!(dh)
        dbcs = DirichletBoundaryConditions(dh)

        # Microhard
        ViscoCrystalPlast.add_dirichletbc!(dbcs, :γ1, VP.node_set(mesh_fine, "slip_boundary"), (x,t) -> 0.0)
        ViscoCrystalPlast.add_dirichletbc!(dbcs, :γ2, VP.node_set(mesh_fine, "slip_boundary"), (x,t) -> 0.0)
        ViscoCrystalPlast.add_dirichletbc!(dbcs, :u, VP.node_set(mesh_fine, "RVE_boundary"), (x,t) -> 0.01 * x, collect(1:dim))

        close!(dbcs)

        pvd_fine = paraview_collection(joinpath(dirname(@__FILE__), "vtks", "shear_primal_fine_$(dim)d_$l"))
        timestep_fine = 0
        exporter_fine = (time, u, f, mss) ->
        begin
            timestep_fine += 1
            mss_nodes = move_quadrature_data_to_nodes(mss, mesh_fine, quad_rule)
            output(pvd_fine, time, timestep_fine, "3d_zerk_$l", mesh_fine, dh, u, f, mss_nodes, quad_rule, mps, polys)
        end

        sol_fine, mss_fine = ViscoCrystalPlast.solve_problem(primal_problem, mesh_fine, dh, dbcs, fe_values, mps, times,
                                                              exporter_fine, polys)
        vtk_save(pvd_fine)

        #tot_slip, tot_grad_en, tot_elastic_en = total_slip(mesh_fine, dofs_fine, sol_fine, mss_fine, fe_values, 2, mp)
        #push!(df_l_study, [l tot_slip tot_grad_en tot_elastic_en])

        ###############################
        # Solve coarse scale problems #
        ###############################
        #=
        for i in 1:7
            mesh_coarse = ViscoCrystalPlast.create_mesh("/home/kristoffer/Dropbox/PhD/Research/CrystPlast/meshes/test_mesh_$i.mphtxt")
            dofs_coarse = ViscoCrystalPlast.add_dofs(mesh_coarse, [:u, :v, :γ1, :γ2], (2,1,1))
            bcs_coarse = ViscoCrystalPlast.DirichletBoundaryConditions(dofs_coarse, mesh_coarse.boundary_nodes, [:u, :v, :γ1, :γ2])
            pvd_coarse = paraview_collection("vtks/shear_primal_coarse")
            timestep_coarse = 0
            exporter_coarse = (time, u, mss) ->
            begin
               timestep_coarse += 1
               mss_nodes = move_quadrature_data_to_nodes(mss, mesh_coarse, quad_rule)
               #output(pvd_coarse, time, timestep_coarse, "shear_primal_coarse", mesh_coarse, dofs_coarse, u, mss_nodes, quad_rule, mp)
            end

            sol_coarse, mss_coarse = ViscoCrystalPlast.solve_problem(primal_problem, mesh_coarse, dofs_coarse, bcs_coarse, fe_values, mp, times,
                                                                   boundary_f_primal, exporter_coarse)

            mss_coarse_nodes = move_quadrature_data_to_nodes(mss_coarse, mesh_coarse, quad_rule)
            sol_fine_interp, mss_fine_nodes_interp = interpolate_to(sol_coarse, mss_coarse_nodes, mesh_coarse,
                                                   mesh_fine, dofs_coarse, dofs_fine, function_space)


            pvd_diff = paraview_collection("vtks/shear_primal_diff")
            sol_diff = sol_fine - sol_fine_interp
            mss_diff = similar(mss_fine)
            global_gp_coords = ViscoCrystalPlast.get_global_gauss_point_coordinates(fe_values, mesh_fine)
            bounding_elements = ViscoCrystalPlast.find_bounding_element_to_gps(global_gp_coords, mesh_coarse)
#
            for i in 1:length(mss_diff)
                mss_diff[i] = mss_fine[i] - mss_coarse[bounding_elements[i]]
                #mss_diff[i] = mss_diff[i] .* mss_diff[i]
            end
            mss_diff_nodes = move_quadrature_data_to_nodes(mss_diff, mesh_fine, quad_rule)
#
            #output(pvd_diff, 1.0, 1, "shear_primal_diff", mesh_fine, dofs_fine, sol_diff, mss_diff_nodes, quad_rule, mp)
            #vtk_save(pvd_diff)

            tot_slip, tot_grad_en, tot_elastic_en = total_slip(mesh_coarse, dofs_coarse, sol_coarse, mss_coarse, fe_values, 2, mp)
            err_tot_slip, err_tot_grad_en, err_tot_elastic_en = total_slip(mesh_fine, dofs_fine, sol_diff, mss_diff, fe_values, 2, mp)
            push!(df, [size(mesh_coarse.topology, 2), l, tot_slip, tot_grad_en, tot_elastic_en, err_tot_slip, err_tot_grad_en, err_tot_elastic_en]')
        end
        =#

    end
    return
    return df, df_l_study


    if write_dataframe
        save(joinpath(dirname(@__FILE__), "dataframes", "primal_l_study_$(now()).jld"), "df", df_l_study)

        save(joinpath(dirname(@__FILE__), "dataframes", "dataframes", "primal_data_frame_$(now()).jld"), "df", df)
    end
    return df
end

function setup_material{dim}(::Type{Dim{dim}}, lα)
    E = 200000.0
    ν = 0.3
    n = 2.0
    #lα = 0.5
    H⟂ = 0.1E
    Ho = 0.1E
    C = 1.0e3
    tstar = 1000.0
    #angles = [20.0, 40.0]
    srand(1234)
    angles = [90 * rand(), 90 * rand()]

    mp = ViscoCrystalPlast.CrystPlastMP(Dim{dim}, E, ν, n, H⟂, Ho, lα, tstar, C, angles)
    return mp
end


function rand_eul()
    α = 2*(rand() - 0.5) * π
    γ = 2*(rand() - 0.5) * π
    β = rand() * π
    return (α, γ, β)
end

function setup_material_3d{dim}(::Type{Dim{dim}}, lα)
    E = 200000.0
    ν = 0.3
    n = 2.0
    lα = 0.5
    H⟂ = 0.1E
    Ho = 0.1E
    C = 1.0e3
    tstar = 1000.0
    ϕs = [rand_eul() for i in 1:2]
    mp = ViscoCrystalPlast.CrystPlastMP(Dim{dim}, E, ν, n, H⟂, Ho, lα, tstar, C, ϕs)
    return mp
end



function output{QD <: QuadratureData, dim}(pvd, time, timestep, filename, mesh, dh, u, f,
                                           mss_nodes::AbstractVector{QD}, quad_rule::QuadratureRule{dim}, mps, polys)
    mp = mps[1]
    nodes_per_ele = dim == 2 ? 3 : 4
    n_sym_components = dim == 2 ? 3 : 6
    tot_nodes = nnodes(mesh)

    vtkfile = vtk_grid(mesh, joinpath(dirname(@__FILE__), "vtks", "$filename" * "_$timestep"))

    vtk_point_data(vtkfile, dh, u)
    #vtk_point_data(vtkfile, dh, f)

    vtk_point_data(vtkfile, reinterpret(Float64, [mss_nodes[i].σ for i in 1:tot_nodes], (n_sym_components, tot_nodes)), "Stress")
    vtk_point_data(vtkfile, reinterpret(Float64, [mss_nodes[i].ε  for i in 1:tot_nodes], (n_sym_components, tot_nodes)), "Strain")
    vtk_point_data(vtkfile, reinterpret(Float64, [mss_nodes[i].ε_p for i in 1:tot_nodes], (n_sym_components, tot_nodes)), "Plastic strain")
    for α in 1:length(mp.angles)
        vtk_point_data(vtkfile, Float64[mss_nodes[i].τ[α] for i in 1:tot_nodes], "Schmid $α")
        vtk_point_data(vtkfile, Float64[mss_nodes[i].τ_di[α] for i in 1:tot_nodes], "Tau dissip $α")
        vtk_point_data(vtkfile, Float64[mss_nodes[i].ξo[α] for i in 1:tot_nodes], "xi o $α")
        vtk_point_data(vtkfile, Float64[mss_nodes[i].ξ⟂[α] for i in 1:tot_nodes], "xi perp $α")
    end

    vtk_cell_data(vtkfile, convert(Vector{Float64}, polys), "poly")
    vtk_save(vtkfile)
    #collection_add_timestep(pvd, vtkfile, time)

end

function total_slip{T, dim}(mesh, dofs, u::Vector{T}, mss, fev::FEValues{dim}, nslip, mp)
    γs = Vector{Vector{T}}(nslip)
    tot_slip = 0.0
    tot_grad_en = 0.0
    tot_elastic_en = 0.0
    ngradvars = 1
    n_basefuncs = n_basefunctions(get_functionspace(fev))
    nnodes = n_basefuncs

    e_coordinates = zeros(dim, n_basefuncs)

    for i in 1:size(mesh.topology, 2)
        ViscoCrystalPlast.element_coordinates!(e_coordinates , mesh, i)
        edof = ViscoCrystalPlast.dofs_element(mesh, dofs, i)
        ug = u[edof]
        x_vec = reinterpret(Vec{2, T}, e_coordinates, (nnodes,))
        reinit!(fev, x_vec)
        for α in 1:nslip
            gd = ViscoCrystalPlast.compute_γdofs(dim, nnodes, ngradvars, nslip, α)
            γs[α] = ug[gd]
        end

        for q_point in 1:length(points(get_quadrule(fev)))
            σ = mss[q_point, i].σ
            ε = mss[q_point, i].ε
            tot_elastic_en += 0.5 * ε ⊡ σ * detJdV(fev, q_point)
            for α = 1:nslip
                ξo = mss[q_point, i].ξo[α]
                ξ⟂ = mss[q_point, i].ξ⟂[α]
                #println(ξo, " ", ξ⟂)
                tot_grad_en += 0.5 / mp.lα^2 * (ξ⟂^2 / mp.H⟂ + ξo^2 / mp.Ho) * detJdV(fev, q_point)
                γ = function_scalar_value(fev, q_point, γs[α])
                tot_slip += γ^2 * detJdV(fev, q_point)
            end
        end
    end
    #println("total nodes: $(size(mesh.edof, 2))")
    #println("effective  slip = $(sqrt(tot_slip))")
    #println("total_grad = $(tot_grad_en)")

    return sqrt(tot_slip), tot_grad_en, tot_elastic_en
end

#startit()
