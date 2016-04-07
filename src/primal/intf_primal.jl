function intf{dim, func_space, T, Q, QD <: CrystPlastPrimalQD}(a::Vector{T}, a_prev, x::AbstractArray{Q}, fev::FEValues{dim, Q, func_space}, fe_u, fe_g,
                            dt, mss::AbstractVector{QD}, temp_mss::AbstractVector{QD}, mp::CrystPlastMP)


    @unpack mp: s, m, l, H⟂, Ho, Ee, sxm_sym
    nslip = length(sxm_sym)


    ngradvars = 1
    n_basefuncs = n_basefunctions(get_functionspace(fev))
    nnodes = n_basefuncs

    @assert length(a) == nnodes * (dim + ngradvars * nslip)
    @assert length(a_prev) == nnodes * (dim + ngradvars * nslip)

    x_vec = reinterpret(Vec{dim, Q}, x, (n_basefuncs,))
    reinit!(fev, x_vec)


    fill!(fe_u, zero(Vec{dim, T}))
    for fe_g_alpha in fe_g
        fill!(fe_g_alpha, zero(T))
    end

    ud = u_dofs(dim, nnodes, ngradvars, nslip)
    a_u = a[ud]
    u_vec = reinterpret(Vec{dim, T}, a_u, (n_basefuncs,))
    γs = Vector{Vector{T}}(nslip)
    γs_prev = Vector{Vector{T}}(nslip)
    for α in 1:nslip
        gd = g_dofs(dim, nnodes, ngradvars, nslip, α)
        γs[α] = a[gd]
        γs_prev[α] = a_prev[gd]
    end

    #H_g = [H⟂ * s[α] ⊗ s[α] + Ho * l[α] ⊗ l[α] for α in 1:nslip]

    for q_point in 1:length(points(get_quadrule(fev)))
        ε = function_vector_symmetric_gradient(fev, q_point, u_vec)
        ε_p = zero(SymmetricTensor{2, dim, T})

        for α in 1:nslip
            γ = function_scalar_value(fev, q_point, γs[α])
            # displacements
            ε_p += γ * sxm_sym[α]
        end

        ε_e = ε - ε_p
        σ = Ee * ε_e
        for i in 1:n_basefuncs
            fe_u[i] +=  σ ⋅ shape_gradient(fev, q_point, i) * detJdV(fev, q_point)
        end

        if T == Float64
            mss[q_point].σ  = σ
            mss[q_point].ε  = ε
            mss[q_point].ε_p = ε_p
        end

        for α in 1:nslip
            γ = function_scalar_value(fev, q_point, γs[α])
            γ_prev = function_scalar_value(fev, q_point, γs_prev[α])

            τα = compute_tau(γ, γ_prev, dt, mp)
            τ_en = -(σ ⊡ sxm_sym[α])

            g = function_scalar_gradient(fev, q_point, γs[α])
            ξ = mp.lα^2 * mp.Hgrad[α] * g
            for i in 1:n_basefuncs
                fe_g[α][i] += (shape_value(fev, q_point, i) * (τα + τ_en) +
                               shape_gradient(fev, q_point, i) ⋅ ξ) * detJdV(fev, q_point)
            end

            if T == Float64
                mss[q_point].g[α] = g
                mss[q_point].τ_di[α] = τα
                mss[q_point].τ[α] = -τ_en
            end
        end
    end

    fe = zeros(a)
    fe_u_jl = reinterpret(T, fe_u, (dim * n_basefuncs,))

    fe[ud] = fe_u_jl
    for α in 1:nslip
        fe[g_dofs(dim, nnodes, ngradvars, nslip, α)] = fe_g[α]
    end

    return fe

end

function compute_tau(γ_gp, γ_gp_prev, ∆t, mp::CrystPlastMP)
    @unpack mp: C, tstar, n
    Δγ = γ_gp - γ_gp_prev
    τ = C * (tstar / ∆t * abs(Δγ))^(1/n)
    return sign(Δγ) * τ
end

