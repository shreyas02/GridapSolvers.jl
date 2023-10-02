# MINRES Solver
struct MINRESSolver <: Gridap.Algebra.LinearSolver
  Pr      :: Union{Gridap.Algebra.LinearSolver,Nothing}
  Pl      :: Union{Gridap.Algebra.LinearSolver,Nothing}
  atol    :: Float64
  rtol    :: Float64
  verbose :: Bool
end

function MINRESSolver(;Pr=nothing,Pl=nothing,atol=1e-12,rtol=1.e-6,verbose=false)
  return MINRESSolver(Pr,Pl,atol,rtol,verbose)
end

struct MINRESSymbolicSetup <: Gridap.Algebra.SymbolicSetup
  solver
end

function Gridap.Algebra.symbolic_setup(solver::MINRESSolver, A::AbstractMatrix)
  return MINRESSymbolicSetup(solver)
end

mutable struct MINRESNumericalSetup <: Gridap.Algebra.NumericalSetup
  solver
  A
  Pr_ns
  Pl_ns
  caches
end

function get_solver_caches(solver::MINRESSolver,A)
  Pl, Pr = solver.Pl, solver.Pr

  V  = [allocate_col_vector(A) for i in 1:3]
  Z  = [allocate_col_vector(A) for i in 1:3]
  zr = !isa(Pr,Nothing) ? allocate_col_vector(A) : nothing
  zl = !isa(Pl,Nothing) ? allocate_col_vector(A) : nothing

  H = zeros(4) # Hessenberg matrix
  g = zeros(2) # Residual vector
  c = zeros(2) # Gibens rotation cosines
  s = zeros(2) # Gibens rotation sines
  return (V,Z,zr,zl,H,g,c,s)
end

function Gridap.Algebra.numerical_setup(ss::MINRESSymbolicSetup, A::AbstractMatrix)
  solver = ss.solver
  Pr_ns  = isa(solver.Pl,Nothing) ? nothing : numerical_setup(symbolic_setup(solver.Pr,A),A)
  Pl_ns  = isa(solver.Pl,Nothing) ? nothing : numerical_setup(symbolic_setup(solver.Pl,A),A)
  caches = get_solver_caches(solver,A)
  return MINRESNumericalSetup(solver,A,Pr_ns,Pl_ns,caches)
end

function Gridap.Algebra.numerical_setup!(ns::MINRESNumericalSetup, A::AbstractMatrix)
  if !isa(ns.Pr_ns,Nothing)
    numerical_setup!(ns.Pr_ns,A)
  end
  if !isa(ns.Pl_ns,Nothing)
    numerical_setup!(ns.Pl_ns,A)
  end
  ns.A = A
end

function Gridap.Algebra.solve!(x::AbstractVector,ns::MINRESNumericalSetup,b::AbstractVector)
  solver, A, Pl, Pr, caches = ns.solver, ns.A, ns.Pl_ns, ns.Pr_ns, ns.caches
  atol, rtol, verbose = solver.atol, solver.rtol, solver.verbose
  V, Z, zr, zl, H, g, c, s = caches
  verbose && println(" > Starting MINRES solver: ")

  Vjm1, Vj, Vjp1 = V
  Zjm1, Zj, Zjp1 = Z

  fill!(Vjm1,0.0); fill!(Vjp1,0.0); copy!(Vj,b)
  fill!(H,0.0), fill!(c,1.0); fill!(s,0.0); fill!(g,0.0)

  mul!(Vj,A,x,-1.0,1.0)
  β    = norm(Vj); β0 = β; Vj ./= β; g[1] = β
  iter = 0
  converged = (β < atol || β < rtol*β0)
  while !converged
    verbose && println("   > Iteration ", iter," - Residual: ", β)

    mul!(Vjp1,A,Vj)
    H[3] = dot(Vjp1,Vj)
    Vjp1 .= Vjp1 .- H[3] .* Vj .- H[2] .* Vjm1
    H[4] = norm(Vjp1)
    Vjp1 ./= H[4]

    # Update QR
    H[1] = s[1]*H[2]; H[2] = c[1]*H[2]
    γ = c[2]*H[2] + s[2]*H[3]; H[3] = -s[2]*H[2] + c[2]*H[3]; H[2] = γ

    # New Givens rotation, update QR and residual
    c[1], s[1] = c[2], s[2]
    c[2], s[2], H[3] = LinearAlgebra.givensAlgorithm(H[3],H[4])
    g[2] = -s[2]*g[1]; g[1] = c[2]*g[1]

    # Update solution
    Zjp1 .= Vj .- H[2] .* Zj .- H[1] .* Zjm1
    Zjp1 ./= H[3]
    x .+= g[1] .* Zjp1

    β  = abs(g[2]); converged = (β < atol || β < rtol*β0)
    Vjm1, Vj, Vjp1 = Vj, Vjp1, Vjm1
    Zjm1, Zj, Zjp1 = Zj, Zjp1, Zjm1
    g[1] = g[2]; H[2] = H[4];
    iter += 1
  end
  verbose && println("   > Num Iter: ", iter," - Final residual: ", β)
  verbose && println("   Exiting MINRES solver.")

  return x
end