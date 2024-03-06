
struct PatchProlongationOperator{A,B,C,D,E}
  op :: A
  Ph :: B
  Vh :: C
  PD :: D
  caches :: E
end

function PatchProlongationOperator(lev,sh,PD,lhs,rhs,qdegree)
  mh = sh.mh
  @assert has_refinement(mh,lev)

  # Default prolongation (i.e interpolation)
  op = ProlongationOperator(lev,sh,qdegree)

  # Patch-based correction fespace
  fmodel = get_model(mh,lev)
  glue = mh.levels[lev].ref_glue
  patches_mask = get_coarse_node_mask(fmodel,glue)

  Vh = MultilevelTools.get_fe_space(sh,lev)
  cell_conformity = sh.levels[lev].cell_conformity
  Ph = PatchFESpace(Vh,PD,cell_conformity;patches_mask)

  # Solver caches
  u, v = get_trial_fe_basis(Vh), get_fe_basis(Vh)
  matdata = collect_cell_matrix(Ph,Ph,lhs(u,v))
  ns = map(local_views(Ph),matdata) do Ph, matdata
    assem = SparseMatrixAssembler(Ph,Ph)
    Ap    = assemble_matrix(assem,matdata)
    numerical_setup(symbolic_setup(LUSolver(),Ap),Ap)
  end
  dxh, dxp, rp = zero_free_values(Vh), zero_free_values(Ph), zero_free_values(Ph)
  caches = ns, rhs, dxh, dxp, rp

  return PatchProlongationOperator(op,Ph,Vh,PD,caches)
end

function LinearAlgebra.mul!(xh,op::PatchProlongationOperator,xH)
  Ap_ns, rhs, dxh, dxp, rp = op.caches

  mul!(xh,op.op,xH)
  duh = FEFunction(op.Vh,xh)
  assemble_vector!(v->rhs(duh,v),rp,op.Ph)
  map(solve!,partition(dxp),Ap_ns,partition(rp))
  inject!(dxh,op.Ph,dxp)

  map(own_values(xh),own_values(dxh)) do xh, dxh
    xh .= xh .- dxh
  end
  consistent!(xh) |> fetch
  return xh
end

function setup_patch_prolongation_operators(sh,patch_decompositions,lhs,rhs,qdegrees)
  mh = sh.mh
  prolongations = Vector{PatchProlongationOperator}(undef,num_levels(sh)-1)
  for lev in 1:num_levels(sh)-1
    parts = get_level_parts(mh,lev)
    if i_am_in(parts)
      qdegree = isa(qdegrees,Number) ? qdegrees : qdegrees[lev]
      PD = patch_decompositions[lev]
      Ω = Triangulation(PD)
      dΩ = Measure(Ω,qdegree)
      rhs_i(u,v) = rhs(u,v,dΩ)
      lhs_i(u,v) = lhs(u,v,dΩ)
      prolongations[lev] = PatchProlongationOperator(lev,sh,PD,lhs_i,rhs_i,qdegree)
    end
  end
  return prolongations
end

function get_coarse_node_mask(fmodel::GridapDistributed.DistributedDiscreteModel,glue)
  gids = get_face_gids(fmodel,0)
  mask = map(local_views(fmodel),glue,partition(gids)) do fmodel, glue, gids
    mask = get_coarse_node_mask(fmodel,glue)
    mask[ghost_to_local(gids)] .= false # Mask ghost nodes as well
    return mask
  end
  return mask
end

# Coarse nodes are the ones that are shared by fine cells that do not belong to the same coarse cell. 
# Conversely, fine nodes are the ones shared by fine cells that all have the same parent coarse cell.
function get_coarse_node_mask(fmodel::DiscreteModel{Dc},glue) where Dc
  ftopo = get_grid_topology(fmodel)
  n2c_map = Gridap.Geometry.get_faces(ftopo,0,Dc)
  n2c_map_cache = array_cache(n2c_map)
  f2c_cells = glue.n2o_faces_map[Dc+1]

  is_coarse = map(1:length(n2c_map)) do n
    nbor_cells = getindex!(n2c_map_cache,n2c_map,n)
    parent = f2c_cells[first(nbor_cells)]
    return any(c -> f2c_cells[c] != parent, nbor_cells)
  end

  return is_coarse
end

function get_patch_interpolators(mh,tests,patch_decomps,Pr,biform,Ah)
  nlevs = num_levels(mh)
  interpolators = Vector{PrologationOperator}(undef,nlevs-1)
  for lev in 1:nlevs-1
    parts = get_level_parts(mh,lev)
    if i_am_in(parts)
      fmodel = get_model(mh,lev)
      cmodel = get_model(mh,lev+1)
      patches_mask = get_patch_masks(fmodel,cmodel)
      PD = patch_decomps[lev]
      Vh = GridapSolvers.MultilevelTools.get_fe_space(tests,lev)
      Ph = get_patch_space(PD,Vh,patches_mask)
      dΩ = Measure(Triangulation(PD),8)
      ap(u,v) = biform(u,v,dΩ)
      I_solver = PatchBasedLinearSolver(ap,Ph,Vh)
      I_ns = numerical_setup(symbolic_setup(I_solver,Ah),Ah)
      interpolators[lev] = PrologationOperator(I_ns,Pr[lev],Ph,Vh,PD)
    end
  end
  return interpolators
end
