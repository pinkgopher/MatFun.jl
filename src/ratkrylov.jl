#=
canonical_cplx checks if the poles p are ordered canonically.
=#
function canonical_cplx(p::Vector{C})::Bool where {C<:Complex}
	m = length(p)
	j = 1
	while j <= m
		if isreal(p[j]) || isinf(p[j])
			j = j+1
		else
			if j == m || p[j+1] != conj(p[j])
				return false
			end
			j = j+2
		end
	end
	return true
end

#=
Moebius transformation with poles p.
p != 0 is replaced by (p, mu) := (p,   1) and (rho, eta) := (1, 0),
p  = 0 is replaced by (p, mu) := (1, Inf) and (rho, eta) := (0, 1).
=#
function poles_to_moebius(p::Vector{Complex{R}})::
	Tuple{Vector{Complex{R}}, Vector{R}, Vector{R}, Vector{R}} where {R<:Real}
	
	p = copy(p)
	mu = ones(R, length(p))
	rho = ones(R, length(p))
	eta = zeros(R, length(p))

	sel = p .== 0

	p[sel] = 1
	mu[sel] = Inf
	rho[sel] = 0
	eta[sel] = 1

	return p, mu, rho, eta
end

function ratkrylov(A::Mat, b::Vector{N}, p::Vector{Complex{R}}) where {
	R<:Union{Float32, Float64}, N<:Union{R, Complex{R}}, Mat<:Union{Matrix{N}, SparseMatrixCSC{N}}}

	B = eye(A)
	m, n = length(p), length(b)
	V = zeros(N, n, m+1)
	K = zeros(N, m+1, m)
	H = zeros(K)
	realopt = N <: Real

	# Cannot use real arithmetic if the poles are not ordered canonically.
	if realopt && !canonical_cplx(p)
		error("can't use real arithmetic")
	end

	p, mu, rho, eta = poles_to_moebius(p)

	# run_krylov:
	bd = false
	bd_tol = eps()
	# Starting vector.
	V[:, 1] = b/norm(b)
	j = 1
	while j <= m
		if realopt && !isreal(p[j])
			# Computing the continuation combination.
			u = ones(Complex{R}, 1) # U[1:j, j] in the original code
			if j > 1
				Q = qr(K[1:j, 1:j-1]/mu[j] - H[1:j, 1:j-1]/p[j], thin=false)[1]
				u = Q[:, end]
			end

			# Compute new vector.
			w = V[:, 1:j]*u
			w = rho[j]*(A*w) - eta[j]*w
			w = (B/mu[j] - A/p[j]) \ w

			# Orthogonalization.
			V[:, j+1] = real(w)
			V[:, j+2] = imag(w)
			# MGS
			for j = j:j+1
				for reo = 0:1
					for reo_i = 1:j
						v = V[:, reo_i]
						hh = v'*V[:, j+1]
						V[:, j+1] -= v*hh
						H[reo_i, j] += hh
					end
				end
				normw = norm(V[:, j+1])
				H[j+1, j] = normw
				V[:, j+1] /= normw
				if normw < bd_tol*norm(H[1:j, j])
					bd = true
					break
				end
			end

			# Setting the decomposition.
			rp, ip = real(1/p[j-1]), imag(1/p[j-1])
			cp = [rp ip; -ip rp]
			u0, h = [real(u) imag(u); 0 0; 0 0], H[1:j+1, j-1:j]
			K[1:j+1, j-1:j] = rho[j-1]*u0 + h*cp
			H[1:j+1, j-1:j] = eta[j-1]*u0 + h/mu[j-1]
		else
			pj = N(p[j])
			# Computing the continuation combination.
			u = ones(N, 1) # U[1:j, j] in the original code
			if j > 1
				Q = qr(K[1:j, 1:j-1]/mu[j] - H[1:j, 1:j-1]/pj, thin=false)[1]
				u = Q[:, end]
			end

			# Compute new vector.
			w = V[:, 1:j]*u
			w = rho[j]*(A*w) - eta[j]*w
			w = (B/mu[j] - A/pj) \ w

			# Orthogonalization, MGS.
			for reo = 0:1
				for reo_i = 1:j
					v = V[:, reo_i]
					hh = v'*w
					w -= v*hh
					H[reo_i, j] += hh
				end
			end
			normw = norm(w)
			H[j+1, j] = normw
			V[:, j+1] = w/normw
			if normw < bd_tol*norm(H[1:j, j])
				bd = true
				break
			end

			# Setting the decomposition.
			u0, h = [u; 0], H[1:j+1, j]
			K[1:j+1, j] = rho[j]*u0 + h/pj
			H[1:j+1, j] = eta[j]*u0 + h/mu[j]
		end # realopt

		j = j+1
	end # while j <= m

	if bd == true
		println("lucky breakdown")
		V = V[:, 1:j]
		K = K[1:j, 1:j-1]
		H = H[1:j, 1:j-1]
	end
	return V, K, H
end

function ratkrylovf(f::Func, A::Mat, b::Vector{N}, p::Vector{Complex{R}}) where {
	Func, R<:Union{Float32, Float64}, N<:Union{R, Complex{R}}, Mat<:Union{Matrix{N}, SparseMatrixCSC{N}}}

	V, K, H = ratkrylov(A, b, p)

	m = size(V, 2) - 1 # may be < length(p) in case of breakdown
	Am = isinf(p[m]) ? [H/K[1:m,1:m] V'*(A*V[:,end])] : V'*A*V

	return V*(schurparlett(f, Am)*(V'*b))
end

#=
automatic poles selection:
=#
function ratkrylovf(f::Func, A::Mat, b::Vector{N}, mmax::Int64=100) where {
	Func, N<:Union{Float32, Float64, Complex64, Complex128}, Mat<:Union{Matrix{N}, SparseMatrixCSC{N}}}

	rad = Mat<:SparseMatrixCSC ? min(norm(A, 1), norm(A, Inf)) : norm(A, 2)
	rad = max(rad, real(N)(sqrt(eps())))

	nsamples = Mat<:SparseMatrixCSC ? nnz(A) : prod(size(A)) # TODO: profile and tweak
	nsamples = max(nsamples, 100)

	pol, res, zer, z = aaa(f, lpdisk(rad, nsamples), 1e-13, mmax)[2:5]
	if N <: Real
		# Assume f(conj(x)) == conj(f(x)),
		# real ratkrylov wants conjugated and canonically ordered poles.
		pos = pol[imag.(pol) .> 0]
		pol = pol[isreal.(pol)]
		for i = 1:length(pos)
			pol = [pol; pos[i]; conj(pos[i])]
		end
	end
	#=
	The poles returned by aaa should be lenght(z)-1, if we get less
	it's because some Inf poles have been filtered away. Add them back:
	(adding at least one allows for faster projection of A in the Krylov space)
	=#
	pol = [pol; fill(N(Inf), max(1, length(z)-1 - length(pol)))]

	return ratkrylovf(f, A, b, pol)
end
