#using PyCall
using Logging
using Dierckx
using IterTools
#using .snake_forward
#using .curve_utils
using Plots
using MATLAB

include("./snake_forward.jl")
include("./curve_utils.jl")
#Reimplementation of Vedranas method with modifications.

#VEDRANA MODIFIED
function displace(centerline_points, force, radius_func, w, w_u, w_l; plot=false)
    L = size(centerline_points,1)
    (outline_xy, normal) = get_outline(centerline_points, radius_func)

    outline_normals = snake_normals(outline_xy)
    forces = force.*outline_normals

    mid = Int64(size(outline_xy,1)/2)#always even
    upper_forces = forces[1:mid,:]
    lower_forces = (forces[mid+1:end, :])[end:-1:1,:]

    upper_points = outline_xy[1:mid,:]
    lower_points = (outline_xy[mid+1:end, :])[end:-1:1,:]

    displaced_upper_points = upper_points .+ w*(upper_forces.*w_u);
    displaced_lower_points = lower_points .+ w*(lower_forces.*w_l);
    displaced_centerline = zeros(L,2)

    displaced_centerline[2:end-1,:] = (displaced_upper_points[3:end-2,:]+displaced_lower_points[3:end-2,:])./2
    displaced_centerline[1,:] = (displaced_upper_points[1,:]+displaced_lower_points[1,:]+displaced_upper_points[2,:]+displaced_lower_points[2,:])./4
    displaced_centerline[L,:] = (displaced_upper_points[end,:]+displaced_lower_points[end,:]+displaced_upper_points[end-1,:]+displaced_lower_points[end-1,:])./4
    if plot
        f = cat(w*(upper_forces.*w_u), (w*(lower_forces.*w_l))[end:-1:1,:], dims = 1).*25
        quiver!(outline_xy[:,1], outline_xy[:,2], quiver=(f[:,1], f[:,2]), color=:gray)
    end
    return displaced_centerline
end

function move_points(residual,curves,angles,N,centerline_points,r,w,w_u, w_l; plot=false)
    (x_length, y_length) = size(residual)
    vals = zeros(Float64, N)
    if y_length > 1
        F = Spline2D(collect(1:1.0:x_length), collect(1:1.0:y_length), residual, kx=1, ky=1);
        vals = zeros(Float64, N)
        for i = 1:length(angles)
            interp = F(curves[:,i], repeat([i], N))
            vals += interp
        end
    else
        F = Spline1D(collect(1:1.0:x_length), residual[:,1], k=1);
        interp = F(curves[:,1])
        vals = interp
    end

    force = vals*(1/length(angles))

    centerline_points = displace(centerline_points, force, r, w, w_u, w_l, plot=plot)
    return centerline_points
end

function to_pixel_coordinates(current, angles, bins)
    N = size(current,1);
    vertex_coordinates = zeros(Float64,N,length(angles));
    a = (length(bins)-1)/(bins[end]-bins[1]); # slope
    b = 1-a*bins[1]; # intercept
    for k = 1:length(angles)
        angle = angles[k]
        projection = [cos(angle) sin(angle)]';
        #expressing vertex coordinates as coordinates in sinogram (pixel coordinates, not spatial)
        vertex_coordinates[:,k] = (current*projection)*a.+b;
    end
    return vertex_coordinates
end

function evolve_curve(sinogram_target, centerline_points, r, angles, bins, max_iter, w, w_u, w_l, smoothness, degree::Int64; plot=false)
    (current, normal) = get_outline(centerline_points, r)
    current_sinogram = parallel_forward(current,angles,bins)

    curves = to_pixel_coordinates(current, angles, bins);
    mu = sum(sinogram_target[:].*current_sinogram[:])/sum(current_sinogram[:].^2)
    residual = sinogram_target - mu*current_sinogram
    N = size(current,1)
    centerline_start = centerline_points[1,:]
    for iter  = 1:max_iter
        centerline_points = move_points(residual,curves,angles,N,centerline_points,r, w, w_u,w_l, plot=plot)

        L = size(centerline_points,1)
        #HACK
        cp = eliminate_loopy_stuff(centerline_points, 2*r(0.0))
        #HACK
        if size(cp,1) > degree
            centerline_points = cp
        else
            @warn "Too loopy"
        end
        t = curve_lengths(centerline_points)

        spl = ParametricSpline(t,centerline_points',k=degree, s=0.0)
        #HACK
        if smoothness > 0.0
            try
                spl = ParametricSpline(t,centerline_points',k=degree, s=smoothness)
            catch e
                @warn e
            end
        end

        tspl = range(0, t[end], length=L)
        centerline_points = collect(spl(tspl)')
        centerline_points[1,:] = centerline_start
        (current, normal) = get_outline(centerline_points, r)
        current_sinogram = parallel_forward(current,angles,bins);
        curves = to_pixel_coordinates(current, angles, bins);
        mu = sum(sinogram_target[:].*current_sinogram[:])/sum(current_sinogram[:].^2)
        residual = sinogram_target - mu*current_sinogram;
    end
    return centerline_points
end

function recon2d_tail(centerline_points::AbstractArray{T,2}, r, angles::Array{T},bins::Array{T},sinogram_target::Array{T,2}, max_iter::Int, smoothness::T, w::T, degree::Int64, w_u::Array{T}, w_l::Array{T}; plot=false) where T<:AbstractFloat
    current = evolve_curve(sinogram_target, centerline_points, r, angles, bins, max_iter, w, w_u, w_l, smoothness, degree, plot=plot)
    return current
end


# #VEDRANA ORIGINAL
function regularization_matrix(N,alpha,beta)
    cwd = @__DIR__
    println(cwd)
    mat"[$B, $A] = regularization_matrix($N,$alpha,$beta);"
    return B
end
#
function remove_crossings(curve)
    mat"$curve = remove_crossings($curve);"
    return curve
end
#
function distribute_points(curve)
    curve = cat(dims = 1, curve, curve[1,:]'); # closing the curve
    N = size(curve,1); # number of points [+ 1, due to closing]
    dist = sqrt.(sum(diff(curve, dims=1).^2, dims=2))[:,1]; # edge segment lengths
    t = prepend!(cumsum(dist, dims=1)[:,1],0.0) # total curve length

    tq = range(0,t[end],length=N); # equidistant positions
    curve_new_1 = Spline1D(t,curve[:,1], k=1).(tq); # distributed x
    curve_new_2 = Spline1D(t,curve[:,2], k=1).(tq); # distributed y
    curve_new = hcat(curve_new_1,curve_new_2); # opening the curve again
    return curve_new[1:end-1,:]
end

function move_points(residual,curves,angles,N,centerline_points,r,w,w_u, w_l; plot=false)
    (x_length, y_length) = size(residual)
    vals = zeros(Float64, N)
    if y_length > 1
        F = Spline2D(collect(1:1.0:x_length), collect(1:1.0:y_length), residual, kx=1, ky=1);
        vals = zeros(Float64, N)
        for i = 1:length(angles)
            interp = F(curves[:,i], repeat([i], N))
            vals += interp
        end
    else
        F = Spline1D(collect(1:1.0:x_length), residual[:,1], k=1);
        interp = F(curves[:,1])
        vals = interp
    end

    force = vals*(1/length(angles))

    centerline_points = displace(centerline_points, force, r, w, w_u, w_l, plot=plot)
    return centerline_points
end

function move_points_original(residual,curves,angles,N,current,B,w)
    (x_length, y_length) = size(residual)
    #F = Spline2D(collect(1:1.0:x_length), collect(1:1.0:y_length), residual, kx=1, ky=1);
    vals = zeros(Float64, N)
    if y_length > 1
        F = Spline2D(collect(1:1.0:x_length), collect(1:1.0:y_length), residual, kx=1, ky=1);
        vals = zeros(Float64, N)
        for i = 1:length(angles)
            interp = F(curves[:,i], repeat([i], N))
            vals += interp
        end
    else
        F = Spline1D(collect(1:1.0:x_length), residual[:,1], k=1);
        interp = F(curves[:,1])
        vals = interp
    end
    force = vals*(1/length(angles))
    normals = snake_normals(current)
    vectors = force.*normals
    current = current + w*vectors;
    current = distribute_points(remove_crossings(B*current))
    return current
end

function evolve_curve_original(sinogram_target, current, angles, bins, B, max_iter, w)
    current_sinogram = parallel_forward(current,angles,bins)

    curves = to_pixel_coordinates(current, angles, bins);

    mu = sum(sinogram_target[:].*current_sinogram[:])/sum(current_sinogram[:].^2)
    residual = sinogram_target - mu*current_sinogram
    N = size(current,1)

    for iter  = 1:max_iter
        current = move_points_original(residual,curves,angles,N,current,B,w);
        current_sinogram = parallel_forward(current,angles,bins);
        curves = to_pixel_coordinates(current, angles, bins);
        mu = sum(sinogram_target[:].*current_sinogram[:])/sum(current_sinogram[:].^2)
        residual = sinogram_target - mu*current_sinogram;
    end
    return current
end

function vedrana(current::Array{T,2},angles::Array{T},bins::Array{T},sinogram_target::Array{T,2}, max_iter::Int, alpha::T, beta::T, w::T) where T<:AbstractFloat
    N = size(current,1)
    B = regularization_matrix(N,alpha,beta)
    current = evolve_curve_original(sinogram_target, current, angles, bins, B, max_iter, w)
    return current
end
#