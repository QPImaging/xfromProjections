#using XfromProjections
#using XfromProjections.curve_utils
#using XfromProjections.snake_forward
using LinearAlgebra
using IterTools

include("./utils.jl")
include("../../phantoms/sperm_phantom.jl")
include("../snake_forward.jl")
include("../snake.jl")
include("../curve_utils.jl")
using Plots
using Colors
using Random

Random.seed!(0)

function plot_update(curve, residual, name)
    #if norm(residual) < tolerance
    @info "plotted"
    label_txt = @sprintf "%s_%f" name norm(residual)
    plot!(curve[:,1], curve[:,2], aspect_ratio=:equal, label=label_txt, linewidth=2)
    #end
end

cwd = @__DIR__
savepath = normpath(joinpath(@__DIR__, "result"))
!isdir(savepath) && mkdir(savepath)

images, tracks = get_sperm_phantom(301,grid_size=0.1)

detmin, detmax = -38.0, 38.0
grid = collect(detmin:0.1:detmax)
bins = collect(detmin:0.125:detmax)

ang = π/2
angles, max_iter, stepsize = [ang], 10000, 0.1
tail_length = curve_lengths(tracks[end])[end]
num_points = 30
r(s) = 1.0
frames2reconstruct = collect(1:10:300)
reconstructions = zeros(num_points,2,length(frames2reconstruct)+1)
#Add actual track at the end so rand sperm works and we can compare timewise
centerline_points = tracks[frames2reconstruct[end]+10]
t = curve_lengths(centerline_points)
spl = ParametricSpline(t,centerline_points',k=1, s=0.0)
tspl = range(0, t[end], length=num_points)
reconstructions[:,:,end] = spl(tspl)'
tolerance = 2.0
for (iter, frame_nr) in Base.Iterators.reverse(enumerate(frames2reconstruct))
    @info iter frame_nr

    #Get projection
    @info "making forward projection for frame: " frame_nr
    outline, normals = get_outline(tracks[frame_nr], r)
    projection = parallel_forward(outline, [ang], bins)

    #Add noise
    @info "adding gaussian noise at level 0.01"
    rho = 0.01
    e = randn(size(projection));
    e = rho*norm(projection)*e/norm(e);
    projection = projection + e;

    #Get ground truth of same length as recon
    t = curve_lengths(tracks[frame_nr])
    spl = ParametricSpline(t,tracks[frame_nr]', k=1, s=0.0)
    tspl = range(0, t[end], length=num_points)
    gt = spl(tspl)'

    angles = [ang]

    w = ones(num_points+2)
    w[1] = 0.0
    w[2] = 0.0

    recon1_ok = false
    recon2_ok = false

    best_residual = Inf
    best_recon = get_straight_template(projection[:,1], r, [0.0 0.0], ang, num_points,bins)
    heatmap(grid, grid, Gray.(images[:,:,frame_nr]), yflip=false, aspect_ratio=:equal, framestyle=:none, legend=true)
    cd(savepath)
    @info "setting up template"
    template = get_straight_template(projection[:,1], r, [0.0 0.0], ang, num_points,bins)
    plot!(template[:,1], template[:,2], label=@sprintf "template")
    @info "calculating initial reconstruction"
    #Reconstruct with weights only on one side
    recon1 = recon2d_tail(deepcopy(template),r,[ang],bins,projection,max_iter, 0.0, stepsize, 1, w, zeros(num_points+2))
    recon2 = recon2d_tail(deepcopy(template),r,[ang],bins,projection,max_iter, 0.0, stepsize, 1, zeros(num_points+2), w)
    best_residual, best_recon[:,:], residual1, residual2 = try_improvement(best_residual, recon1, recon2, ang, bins, projection, best_recon, tail_length, r)
    plot_update(best_recon, best_residual, "initial")

    for i = 1:1
        if best_residual < 1.0
            break
        end
        @info "checking if any parts could need mirroring"
        initial1 = deepcopy(recon1)
        initial2 = deepcopy(recon2)

        for flip_pt=1:num_points
            recon1_flipped = flip(initial1,flip_pt,ang)
            recon2_flipped = flip(initial2,flip_pt,ang)

            best_residual, best_recon[:,:], residual1, residual2 = try_improvement(best_residual, recon1_flipped, recon2_flipped, ang, bins, projection, best_recon, tail_length, r)

            #mirror and reconstruct with weights on both sides
            recon1 = recon2d_tail(deepcopy(recon1_flipped),r,[ang],bins,projection,100, 0.0, stepsize, 1, w, zeros(num_points+2))
            recon2 = recon2d_tail(deepcopy(recon2_flipped),r,[ang],bins,projection,100, 0.0, stepsize, 1, zeros(num_points+2), w)
            best_residual, best_recon[:,:], residual1, residual2 = try_improvement(best_residual, recon1, recon2, ang, bins, projection, best_recon, tail_length, r)

            recon1 = recon2d_tail(deepcopy(recon1_flipped),r,[ang],bins,projection,100, 0.0, stepsize, 1, zeros(num_points+2), w)
            recon2 = recon2d_tail(deepcopy(recon2_flipped),r,[ang],bins,projection,100, 0.0, stepsize, 1, w, zeros(num_points+2))
            best_residual, best_recon[:,:], residual1, residual2 = try_improvement(best_residual, recon1, recon2, ang, bins, projection, best_recon, tail_length, r)
        end
        plot_update(best_recon, best_residual, "flip1")
        if best_residual < 1.0
            break
        end

        for (flip_i,flip_j) in subsets(1:num_points, Val{2}())
            recon1_flipped = flip(initial1,flip_i,ang)
            recon1_flipped = flip(recon1_flipped,flip_j,ang)
            recon2_flipped = flip(initial2,flip_i,ang)
            recon2_flipped = flip(recon2_flipped,flip_j,ang)

            best_residual, best_recon[:,:], residual1, residual2 = try_improvement(best_residual, recon1_flipped, recon2_flipped, ang, bins, projection, best_recon, tail_length, r)

            recon1 = recon2d_tail(deepcopy(recon1_flipped),r,[ang],bins,projection,100, 0.0, stepsize, 1, w, zeros(num_points+2))
            recon2 = recon2d_tail(deepcopy(recon2_flipped),r,[ang],bins,projection,100, 0.0, stepsize, 1, zeros(num_points+2), w)
            best_residual, best_recon[:,:], residual1, residual2 = try_improvement(best_residual, recon1, recon2, ang, bins, projection, best_recon, tail_length, r)

            recon1 = recon2d_tail(deepcopy(recon1_flipped),r,[ang],bins,projection,100, 0.0, stepsize, 1, zeros(num_points+2), w)
            recon2 = recon2d_tail(deepcopy(recon2_flipped),r,[ang],bins,projection,100, 0.0, stepsize, 1, w, zeros(num_points+2))
            best_residual, best_recon[:,:], residual1, residual2 = try_improvement(best_residual, recon1, recon2, ang, bins, projection, best_recon, tail_length, r)
        end
        plot_update(best_recon, best_residual, "flip2")
        if best_residual < 1.0
            break
        end

        # @info "keeping the best parts and restarting reconstruction"
        # recon_best = keep_best_parts(residual1, deepcopy(best_recon), ang, bins, 1, num_points, tail_length, projection[:,1], r)
        # recon1 = recon2d_tail(deepcopy(recon_best),r,[ang],bins,projection,max_iter, 0.0, stepsize, 1, w, zeros(num_points+2))
        # recon2 = recon2d_tail(deepcopy(recon_best),r,[ang],bins,projection,max_iter, 0.0, stepsize, 1, zeros(num_points+2), w)
        # best_residual, best_recon[:,:], residual1, residual2 = try_improvement(best_residual, recon1, recon2, ang, bins, projection, best_recon, tail_length, r)
        # plot_update(best_recon, best_residual, "best")
    end
    reconstructions[:,:,iter] = best_recon
    #plot!(best_recon[:,1], best_recon[:,2], aspect_ratio=:equal, label=best_residual, linewidth=2)
    savefig(@sprintf "heuristic_result_%d" frame_nr)
    heatmap(grid, grid, Gray.(images[:,:,frame_nr]), yflip=false, aspect_ratio=:equal, framestyle=:none, legend=false)
    plot!(best_recon[:,1], best_recon[:,2], aspect_ratio=:equal, linewidth=2)
    mirror = flip(best_recon,1,ang)
    plot!(mirror[:,1], mirror[:,2], aspect_ratio=:equal, linewidth=2)
    savefig(@sprintf "result_%d" frame_nr)
end

global ps = AbstractPlot[]
for (iter, frame_nr) in enumerate(frames2reconstruct)
    best_recon = reconstructions[:,:,iter]
    mirror = flip(best_recon,1,ang)

    l = @layout [a b c]
    p = heatmap(grid, grid, Gray.(images[:,:,frame_nr]), yflip=false, aspect_ratio=:equal, framestyle=:none, legend=false)
    plot!(best_recon[:,1],best_recon[:,2], aspect_ratio=:equal, linewidth=5)
    plot!(mirror[:,1], mirror[:,2], aspect_ratio=:equal, linewidth=5)
    push!(ps,p)
    if length(ps) == 3
        plot(ps[1], ps[2], ps[3], layout = l, size=(2000,600), linewidth=5)
        savefig(@sprintf "result_all_%d" frame_nr)
        global ps = AbstractPlot[]
    end
end
cd(cwd)