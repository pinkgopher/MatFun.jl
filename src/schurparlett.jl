#=
This file implements the algorithm described in:
"A Schur-Parlett Algorithm for Computing Matrix Functions"
(Davies and Higham, 2003)
One major modification was made to the algorithm:
it works in real arithmetic for real matrices.
=#

#=
blockpattern groups eigenvalues in sets, implementing Algorithm 4.1 of the paper.
The function returns S and p. S is the pattern, where S[i] = s means that
vals[i] has been assigned to set s. p is the number of sets identified.
=#
delta = 0.1
function blockpattern(vals::Vector{C}, schurtype::Type)::Tuple{Vector{Int64}, Int64} where {C<:Complex}
	unassigned = -1
	S = fill(unassigned, length(vals))
	p = 0

	# assign vals[i] to set s.
	function assign(i::Int64, s::Int64)
		lambda = vals[i]
		for k = i:length(vals)
			if vals[k] == lambda
				S[k] = s
			end
		end
	end
	function mergesets(s::Int64, t::Int64)
		if s == t
			return
		end
		smin, smax = minmax(s, t)
		for k = 1:length(vals)
			if S[k] == smax
				S[k] = smin
			elseif S[k] > smax
				S[k] -= 1
			end
		end
		p -= 1
	end

	for i = 1:length(vals)
		if S[i] == unassigned
			p += 1
			assign(i, p)
		end
		for j = i+1:length(vals)
			if abs(vals[i]-vals[j]) <= delta
				if S[j] == unassigned
					assign(j, S[i])
				else
					mergesets(S[i], S[j])
				end
			end
		end
	end

	if schurtype <: Real
		# complex conjugate eigenvalues can't be separated in the
		# real Schur factorization, so we merge the sets involving them:
		i = 1
		while i < length(vals)
			if imag(vals[i]) != 0
				mergesets(S[i], S[i+1])
				i += 2
			else
				i += 1
			end
		end
	end
	return S, p
end

#=
reorder reorders the Schur decomposition (T, Q, vals) according to pattern S,
using the swapping strategy described in Algorithm 4.2.
The returned vector, blockend, contains the indices at which each block ends
(after the reordering).
=#
function reorder!(T::Matrix{N}, Q::Matrix{N}, vals::Vector{C}, S::Vector{Int64}, p::Int64)::Vector{Int64} where {N<:Number, C<:Complex}
	# for each set, calculate its mean position in S:
	pos = zeros(Float64, p)
	cou = zeros(Int64, p)
	for i = 1:length(S)
		set = S[i]
		pos[set] += i
		cou[set] += 1
	end
	pos ./= cou

	# analogous to ordschur/trsen:
	function ordvec!(v::Vector{T}, select::Vector{Bool}) where {T}
		ilst = 1
		for ifst = 1:length(v)
			if select[ifst]
				if ifst != ilst
					v[ilst], v[ilst+1:ifst] = v[ifst], v[ilst:ifst-1]
				end
				ilst += 1
			end
		end
	end

	blockend = zeros(Int64, p)
	for set = 1:p
		numordered = (set == 1) ? 0 : blockend[set-1]
		minset = indmin(pos)
		select = [i <= numordered || S[i] == minset for i = 1:length(S)]
		ordschur!(T, Q, select)
		ordvec!(vals, select)
		ordvec!(S, select)
		blockend[set] = count(select)
		pos[minset] = Inf
	end
	return blockend
end

#=
evaltaylor computes f(T) using Taylor as described in Algorithm 2.6.
=#
function evaltaylor(f::Func, T::Mat, shift::N)::Mat where {Func, N<:Number, Mat<:Union{Matrix{N}, UpperTriangular{N, Matrix{N}}}}
	maxiter = 300
	lookahead = 10
	tay = f(shift + Taylor1(N, 20+lookahead))
	M = T - shift*Mat(eye(T))
	P = M
	F = tay.coeffs[1]*Mat(eye(T))
	for k = 1:maxiter
		needorder = k + lookahead
		@assert needorder <= tay.order + 1
		if needorder > tay.order
			tay = f(shift + Taylor1(N, min(maxiter+lookahead, tay.order*2)))
		end

		Term = tay.coeffs[k+1] * P
		F += Term
		normP = norm(P, Inf)
		P *= M
		small = eps()*norm(F, Inf)
		if norm(Term, Inf) <= small
			#=
			The termination condition is loosely inspired to the one in the paper.
			We check that the next lookahead terms in the series are small,
			estimating ||M^(k+r)|| with max(||M^k||, ||M^(k+1)||).
			Works well in practice, at least for exp, log and sqrt.
			=#
			delta = maximum(abs.(tay.coeffs[k+2:k+1+lookahead]))
			if delta*max(normP, norm(P, Inf)) <= small
				return F
			end
		end
	end
	error("Taylor did not converge.")
end

function atomicblock(f::Func, T::Matrix{R}, vals::Vector{Complex{R}}) where {Func, R<:Real}
	# handle here case size(T) == 1
	Fr = Matrix{R}(0, 0)
	if any(imag.(vals) .== 0) # find a better one?
		me = mean(real.(vals))
		Fr = evaltaylor(f, T, me)
	else
		me = mean(filter((x) -> imag(x) >= 0, vals))
		Fc = evalhermite(f, Matrix{Complex{R}}(T), me, conj(me))
		Fr = real.(Fc)
		if norm(imag.(Fc), Inf) > 1000*eps()*norm(Fr, Inf)
			error("T is a real matrix and f(T) has a non-negligible imaginary part.")
			# you may want to run the complex version of schurparlett.
		end
	end
	return Fr
end
function atomicblock(f::Func, T::Matrix{C}, vals::Vector{C}) where {Func, C<:Complex}
	return evaltaylor(f, T, mean(vals))
end

#=
parlettrec computes and returns f(T) using the Parlett recurrence.
T is block-triangular and blockend contains the indices at which each block ends.
The paper suggests to do the recurrence iteratively (Algorithm 5.1), we do it
recursively. We experimented with various versions of the Parlett recurrence,
this gave us the best performance.
=#
function parlettrec(f::Func, T::Matrix{Num}, vals::Vector{C}, blockend::Vector{Int64}) where {Func, Num<:Number, C<:Complex}

	@assert length(blockend) > 0
	if length(blockend) == 1
		return atomicblock(f, T, vals)
	end

	# split T in 2x2 superblocks of size ~n/2:
	n = size(T, 1)
	b = indmin(abs.(blockend .- n/2))
	bend = blockend[b]
	T11, T12 = T[1:bend, 1:bend], view(T, 1:bend, bend+1:n)
	T21, T22 = view(T, bend+1:n, 1:bend), T[bend+1:n, bend+1:n]

	F11 = parlettrec(f, T11, blockend[1:b])
	F22 = parlettrec(f, T22, blockend[b+1:end] .- bend) # vals!!!!!
	
	# T11*F12 - F12*T22 = F11*T12 - T12*F22
	F12, scale = LAPACK.trsyl!('N', 'N', T11, T22, F11*T12 - T12*F22, -1)

	return [F11 F12/scale; zeros(T21) F22]
end

function schurparlett(f::Func, A::Matrix{C}) where {Func, C<:Complex}
	if istriu(A)
		return schurparlett(f, A, eye(A))
	end

	T, Q, vals = gees!(A)
	return schurparlett(f, T, Q)
end

function schurparlett(f::Func, T::Matrix{Comp}, Q::Matrix{Comp}) where {Func, Comp<:Complex}
	if isdiag(T)
		return Q*diagm(f.(diag(T)))*Q'
	end

	vals = diag(T)
	S, p = blockpattern(vals, 0.1)
	T, Q = copy(T), copy(Q)
	blocksize = reorder!(T, Q, S, p)
	F = parlettrec(f, T, cumsum(blocksize))
	return Q*F*Q'
end
