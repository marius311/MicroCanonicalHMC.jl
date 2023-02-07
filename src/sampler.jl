mutable struct Hyperparameters{T}
     eps ::T
     L::T
     nu::T
     lambda_c::T
end

Hyperparameters(;kwargs...) = begin
    eps = get(kwargs, :eps, 0.0)
    L = get(kwargs, :L, 0.0)
    nu = get(kwargs, :nu, 0.0)
    lambda_c = get(kwargs, :lambda_c, 0.1931833275037836)
    Hyperparameters(eps, L, nu, lambda_c)
end

mutable struct Settings
    key::MersenneTwister
    varE_wanted::Float64
    burn_in::Int
    tune_samples::Int
    tune_maxiter::Int
    integrator::String
end

Settings(;kwargs...) = begin
    kwargs = Dict(kwargs)
    seed = get(kwargs, :seed, 0)
    key = MersenneTwister(seed)
    varE_wanted = get(kwargs, :varE_wanted, 0.2)
    burn_in = get(kwargs, :burn_in, 0)
    tune_samples = get(kwargs, :tune_samples, 1000)
    tune_maxiter = get(kwargs, :tune_maxiter, 10)
    integrator = get(kwargs, :integrator, "LF")
    Settings(key,
             varE_wanted, burn_in, tune_samples, tune_maxiter,
             integrator)
end

struct Sampler
    settings::Settings
    hyperparameters::Hyperparameters
    hamiltonian_dynamics::Function
end

function Sampler(eps, L; kwargs...)

    sett = Settings(;kwargs...)
    hyperparameters = Hyperparameters(;eps=eps, L=L, kwargs...)

    if sett.integrator == "LF"  # leapfrog
        hamiltonian_dynamics = Leapfrog
        grad_evals_per_step = 1.0
    elseif sett.integrator == "MN"  # minimal norm integrator
        hamiltonian_dynamics = Minimal_norm
        grad_evals_per_step = 2.0
    else
        println(string("integrator = ", integrator, "is not a valid option."))
    end

    return Sampler(sett, hyperparameters, hamiltonian_dynamics)
end

function Random_unit_vector(sampler::Sampler, target::Target;
                            normalize=true)
    """Generates a random (isotropic) unit vector."""
    key = sampler.settings.key
    u = randn(key, target.d)
    if normalize
        u ./=  sqrt.(sum(u.^2))
    end
    return  u

end

function Partially_refresh_momentum(sampler::Sampler, target::Target, u)
    """Adds a small noise to u and normalizes."""
    nu = sampler.hyperparameters.nu
    z = nu .* Random_unit_vector(sampler, target; normalize=false)
    uu = (u .+ z) / sqrt.(sum((u .+ z).^2))
    return uu
end

function Update_momentum(sampler::Sampler, target::Target, eff_eps::Float64, g, u)
    # TO DO: type inputs
    # Have to figure out where and when to define target
    """The momentum updating map of the ESH dynamics (see https://arxiv.org/pdf/2111.02434.pdf)"""

    g_norm = sqrt.(sum(g .^2 ))
    e = - g ./ g_norm
    ue = dot(u, e)
    sh = sinh.(eff_eps * g_norm ./ target.d)
    ch = cosh.(eff_eps * g_norm ./ target.d)
    th = tanh.(eff_eps * g_norm ./ target.d)
    delta_r = @.(log(ch) + log1p(ue * th))

    uu = @.((u + e * (sh + ue * (ch - 1))) / (ch + ue * sh))

    return uu, delta_r
end

function Dynamics(sampler::Sampler, target::Target, state)
    """One step of the Langevin-like dynamics."""

    x, u, g, time = state

    # Hamiltonian step
    xx, gg, uu, kinetic_change = sampler.hamiltonian_dynamics(sampler, target, x, g, u)

    # add noise to the momentum direction
    uuu = Partially_refresh_momentum(sampler, target, uu)

    # why not this??
    # time += eps

    return xx, uuu, gg, kinetic_change, time
end

function Get_initial_conditions(sampler::Sampler, target::Target; kwargs...)
    sett = sampler.settings
    kwargs = Dict(kwargs)
    ### initial conditions ###
    x = get(kwargs, :initial_x, target.prior_draw(sett.key))
    g = target.grad_nlogp(x) .* target.d ./ (target.d - 1)
    u = Random_unit_vector(sampler, target) #random initial direction
    #u = - g / jnp.sqrt(jnp.sum(jnp.square(g))) #initialize momentum in the direction of the gradient of log p

    return (x, u, g, 0.0, 0.0)
end

#=
function Energy(target::Target, x, r)
    return target.d * r + target.nlogp(x)
end
=#

function Energy(target::Target, x, xx, E, kinetic_change)
    nlogp = target.nlogp(x)
    nllogp = target.nlogp(xx)
    EE = E + kinetic_change + nllogp - nlogp
    return -nllogp, EE
end

function Step(sampler::Sampler, target::Target, state; kwargs...)
    """Tracks transform(x) as a function of number of iterations"""
    x, u, g, E, time = state
    step = Dynamics(sampler, target, state)
    xx, uu, gg, kinetic_change, time = step
    if get(kwargs, :monitor_energy, false)
        logp, EE = Energy(target, x, xx, E, kinetic_change)
    else
        logp, EE = -target.nlogp(xx), nothing
    end
    return step, (target.inv_transform(x), EE, logp)
end

function Sample(sampler::Sampler, target::Target, num_steps::Int; kwargs...)
    """Args:
           num_steps: number of integration steps to take.
           x_initial: initial condition for x (an array of shape (target dimension, )). It can also be 'prior' in which case it is drawn from the prior distribution (self.Target.prior_draw).
           random_key: jax radnom seed, e.g. jax.random.PRNGKey(42).
        Returns:
            samples (shape = (num_steps, self.Target.d))
    """

    init = Get_initial_conditions(sampler, target; kwargs...)
    for i in 1:sampler.settings.burn_in
        init, _ = Step(sampler, target, init)
    end
    x, u, g, E, ime = init

    eps = sampler.hyperparameters.eps
    L = sampler.hyperparameters.L
    if [eps, L] == [0.0, 0.0]
        println("Self-tuning hyperparameters")
        tune_hyperparameters(sampler, target, init; kwargs...)
    end

    #TODO: Type
    samples = DataFrame(Ω=Any[], E=Any[], logp=Any[])
    push!(samples, (target.inv_transform(x), E, -target.nlogp(x)))
    for i in 1:num_steps
        init, sample = Step(sampler, target, init; kwargs...)
        push!(samples, sample)
    end

    return samples
end