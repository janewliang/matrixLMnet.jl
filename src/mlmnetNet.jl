"""
    MlmnetNet(B, lambdasL1, lambdasL2, data)

Type for storing the results of an mlmnet (Elastic net) model fit

"""

mutable struct MlmnetNet

    # Coefficient estimates
    B::Array{Float64, 4}

    # Lambda penalties
    lambdas::Array{Float64, 1} # Total penalties
    alphas::Array{Float64, 1} # Penalty ratios
    # lambdasL1::Array{Float64, 1} # L1 penalties
    # lambdasL2::Array{Float64, 1} # L2 penalties
    
    # Response and predictor matrices
    data::RawData
end

"""
    mlmnet_pathwiseNet(fun, X, Y, Z, lambdasL1, lambdasL2, regXidx, regZidx, 
                    reg, norms; isVerbose, stepsize, funArgs...)

Performs the supplied method on two descending lists of lambdas (for l1 and l2) 
using ``warm starts''. 

# Arguments

- fun = function that applies the Elastic-net pentalty estimate method
- X = 2d array of floats consisting of the row covariates, with all 
  categorical variables coded in appropriate contrasts
- Y = 2d array of floats consisting of the multivariate response
- Z = 2d array of floats consisting of the column covariates, with all 
  categorical variables coded in appropriate contrasts
- lambdas = 1d array of floats consisting of the total penalties in descending 
  order. If they are not in descending order, they will be sorted.
- alpha = a float variable, the penalty ratio
- regXidx = 1d array of indices corresponding to regularized X covariates
- regZidx = 1d array of indices corresponding to regularized Z covariates
- reg = 2d array of bits, indicating whether or not to regularize each of the 
  coefficients
- norms = 2d array of floats consisting of the norms corresponding to each 
  coefficient or `nothing`

# Keyword arguments

- isVerbose = boolean flag indicating whether or not to print messages.  
  Defaults to `true`. 
- stepsize = float; step size for updates. Defaults to `0.01`. 
- funArgs = variable keyword arguments to be passed into `fun`

# Value

A 4d array consisting of the coefficient estimates, with the different 
lambdasL1 and lambdasL2 along the first and second dimensions respectively

# Some notes

Assumes that all necessary standardizations have been performed on X, Y, and 
Z, including adding on intercepts. To be called by `mlmnetNet`, which performs 
standardization and backtransforming. 

"""
function mlmnet_pathwiseNet(fun::Function, X::AbstractArray{Float64,2}, 
                         Y::AbstractArray{Float64,2}, 
                         Z::AbstractArray{Float64,2}, 
                         lambdas::AbstractArray{Float64,1},
                         alphas::AbstractArray{Float64, 1},  
                         regXidx::AbstractArray{Int64,1}, 
                         regZidx::AbstractArray{Int64,1}, 
                         reg::BitArray{2}, norms; isVerbose::Bool=true, 
                         stepsize::Float64=0.01, funArgs...)

    # Check that the lambdas are unique and in descending order. 
    if length(lambdas) != length(unique(lambdas))
        println_verbose("Dropping non-unique lambdas", isVerbose)
    end

    # Pre-sort the lambdas in descending order in order to apply warm-starts
    if any(lambdas .!= sort(lambdas, rev=true))
        println_verbose("Sorting total penalty lambdas into descending order.", isVerbose)
        lambdas .= sort(lambdas, rev=true)
    end 

    # Pre-allocate array for coefficients
    # coeffs = Array{Float64}(undef, length(alphas), length(lambdas), size(X,2), size(Z,2)) # issue#10 original
    coeffs = Array{Float64}(undef, size(X,2), size(Z,2), length(lambdas), length(alphas)) # issue#10 ✓

    # Start with coefficients initalized at zero for the largest lambda value
    startB = zeros(size(X,2), size(Z,2))

    # Pre-compute eigenvalues and eigenvectors for ADMM
    # if length(string(fun)) > 7 && (string(fun)[(end-7):end] == "admmNet!") # issue#15 ✓
    if string(fun) == "admmNet!"
        # Eigenfactorization of X
        XTX = transpose(X)*X
        eigX = eigen(XTX)
        Qx = eigX.vectors
        Lx = eigX.values
        
        # Eigenfactorization of Z
        ZTZ = transpose(Z)*Z
        eigZ = eigen(ZTZ)
		    Qz = eigZ.vectors
		    Lz = eigZ.values
    
        # Transformed Y
        X1 = X*Qx
        Z1 = Z*Qz
        U = transpose(X1) * Y * Z1

        # Kronecker product of eigenvalues of Z and X
        L = kron(Lx, transpose(Lz))
    end

    # Iterate through the paths of alphas and lambdas
    for i = 1:length(alphas)
      startB = zeros(size(X,2), size(Z,2)) 
      
      for j = 1:length(lambdas)

        # Get Elastic-net penalty estimates by updating the coefficients from previous 
        # iteration in place
        
        # if length(string(fun)) <= 7 || (string(fun)[(end-7):end] != "admmNet!") # issue#15 ✓
        if (string(fun) != "admmNet!" && string(fun) != "cd")
            # ISTA, FISTA and FISTA with Backtracking (CD not supported for Elastic-net yet)
            fun(X, Y, Z, lambdas[j], alphas[i], startB, regXidx, regZidx, reg, norms; 
                isVerbose=isVerbose, stepsize=stepsize, funArgs...)

        else
            # ADMM 
            fun(X, Y, Z, lambdas[j], alphas[i], startB, regXidx, regZidx, reg, norms, 
                Qx, Qz, U, L; 
                isVerbose=isVerbose, stepsize=stepsize, funArgs...)
        end

        # Assign a slice of coeffs to the current coefficient estimates
        coeffs[:, :, j, i] = startB  #issue#10 ✓
      end
    end

    return coeffs
end

"""
    mlmnetNet(fun, data, lambdas, alpha; 
           isXIntercept, isZIntercept, isXReg, isZReg, 
           isXInterceptReg, isZInterceptReg, isStandardize, isVerbose, 
           stepsize, setStepsize, funArgs...)

Standardizes X and Z predictor matrices, calculates fixed step size, performs 
the supplied method on two descending lists of lambdas (each for L1 and L2) using ``warm starts'', 
and backtransforms resulting coefficients, as is deemed necessary by the user 
inputs.

# Arguments

- fun = function that applies the Elastic-net penalty estimate method
- data = RawData object
- lambdas = 1d array of floats consisting of the total penalties in descending 
  order. If they are not in descending order, they will be sorted. 
- alpha = a float, the penalty ratio

# Keyword arguments

- isNaive = boolean flag indicating whether to solve the Naive or non-Naive 
  Elastic-net problem
- isXIntercept = boolean flag indicating whether or not to include an `X` 
  intercept (row main effects). Defaults to `true`. 
- isZIntercept = boolean flag indicating whether or not to include a `Z` 
  intercept (column main effects). Defaults to `true`.
- isXReg = 1d array of bit flags indicating whether or not to regularize each 
  of the `X` (row) effects. Defaults to 2d array of `true`s with length 
  equal to the number of `X` effects (equivalent to `data.p`). 
- isZReg = 1d array of bit flags indicating whether or not to regularize each 
  of the `Z` (column) effects. Defaults to 2d array of `true`s with length 
  equal to the number of `Z` effects (equivalent to `data.q`). 
- isXInterceptReg = boolean flag indicating whether or not to regularize the 
  `X` intercept Defaults to `false`. 
- isZInterceptReg = boolean flag indicating whether or not to regularize the 
  `Z` intercept. Defaults to `false`. 
- isStandardize = boolean flag indicating if the columns of `X` and `Z` 
  should be standardized (to mean 0, standard deviation 1). Defaults to `true`.
- isVerbose = boolean flag indicating whether or not to print messages.  
  Defaults to `true`. 
- stepsize = float; step size for updates (irrelevant for coordinate 
  descent and when `setStepsize` is set to `true` for `ista!` and `fista!`). 
  Defaults to `0.01`. 
- setStepsize = boolean flag indicating whether the fixed step size should be 
  calculated (for `ista!` and `fista!`). Defaults to `true`.
- funArgs = variable keyword arguments to be passed into `fun`

# Value

An MlmnetNet object

# Some notes

The default method for choosing the fixed step size for `fistaNet!` or `istaNet!` 
is to use the reciprocal of the product of the maximum eigenvalues of 
`X*transpose(X)` and `Z*transpose(Z)`. This is computed when `fista!` or 
`ista!` is passed into the `fun` argument and `setStepsize` is set to `true`. 
If `setStepsize` is set to `false`, the value of the `stepsize` argument will 
be used as the fixed step size. Note that obtaining the eigenvalues when `X` 
and/or `Z` are very large may exceed computational limitations. 

Specifying a good starting step size (`stepsize`) and multiplying factor 
(`gamma`) when `fista_bt!` is passed into the `fun` argument can be difficult. 
Shrinking the step size too gradually can result in slow convergence. Doing so 
too quickly can cause the criterion to diverge. We have found that setting 
`stepsize` to 0.01 often works well in practice; choice of `gamma` appears to 
be less consequential. 

"""
# function mlmnetNet(fun::Function, data::RawData, # To delete
#                 lambdas::AbstractArray{Float64,1}, alphas::AbstractArray{Float64,1};
#                 isNaive::Bool=false,
#                 isXIntercept::Bool=true, isZIntercept::Bool=true, 
#                 isXReg::BitArray{1}=trues(data.p), 
#                 isZReg::BitArray{1}=trues(data.q),     
#                 isXInterceptReg::Bool=false, isZInterceptReg::Bool=false, 
#                 isStandardize::Bool=true, isVerbose::Bool=true, 
#                 stepsize::Float64=0.01, setStepsize::Bool=true, 
#                 funArgs...)
function mlmnetNet(data::RawData, 
                lambdas::AbstractArray{Float64,1}, alphas::AbstractArray{Float64,1};
                method::String = "ista", 
                isNaive::Bool=false,
                isXIntercept::Bool=true, isZIntercept::Bool=true, 
                isXReg::BitArray{1}=trues(data.p), 
                isZReg::BitArray{1}=trues(data.q),     
                isXInterceptReg::Bool=false, isZInterceptReg::Bool=false, 
                isStandardize::Bool=true, isVerbose::Bool=true, 
                stepsize::Float64=0.01, setStepsize::Bool=true, 
                funArgs...)
    
    # Get the function according to the selected method             
    fun = getFunc(method);

    # Ensure that isXReg and isZReg have same length as columns of X and Z
    if length(isXReg) != data.p
        error("isXReg does not have same length as number of columns in X.")
    end
    if length(isZReg) != data.q
        error("isZReg does not have same length as number of columns in Z.")
    end 
    
    # Add X and Z intercepts if necessary
    # Update isXReg and isZReg accordingly
    if isXIntercept==true && data.predictors.isXIntercept==false
        data.predictors.X = add_intercept(data.predictors.X)
        data.predictors.isXIntercept = true
        data.p = data.p + 1
        isXReg = vcat(isXInterceptReg, isXReg)
    end
    if isZIntercept==true && data.predictors.isZIntercept==false
        data.predictors.Z = add_intercept(data.predictors.Z)
        data.predictors.isZIntercept = true
        data.q = data.q + 1
        isZReg = vcat(isZInterceptReg, isZReg)
    end
    
    # Remove X and Z intercepts in new predictors if necessary
    # Update isXReg and isZReg accordingly
    if isXIntercept==false && data.predictors.isXIntercept==true
        data.predictors.X = remove_intercept(data.predictors.X)
        data.predictors.isXIntercept = false
        data.p = data.p - 1
        isXReg = isXReg[2:end]
    end

    if isZIntercept==false && data.predictors.isZIntercept==true
        data.predictors.Z = remove_intercept(data.predictors.Z)
        data.predictors.isZIntercept = false
        data.q = data.q - 1
        isZReg = isZReg[2:end]
    end
    
    # Update isXReg and isZReg accordingly when intercept is already included
    if isXIntercept==true && data.predictors.isXIntercept==true
        isXReg[1] = isXInterceptReg
    end
    if isZIntercept==true && data.predictors.isZIntercept==true
        isZReg[1] = isZInterceptReg
    end
	
    # Matrix to keep track of which coefficients to regularize.
    reg = isXReg.*transpose(isZReg) 
    # Indices corresponding to regularized X covariates. 
    regXidx = findall(isXReg) 
    # Indices corresponding to regularized Z covariates. 
    regZidx = findall(isZReg) 

    # Standardize predictors, if necessary. 
    if (isStandardize==true)
        # If predictors will be standardized, copy the predictor matrices.
        X = copy(get_X(data))
        Z = copy(get_Z(data))

        # Standardize predictors
        meansX, normsX, = standardize!(X, isXIntercept) 
        meansZ, normsZ, = standardize!(Z, isZIntercept)
        # If X and Z are standardized, set the norm to nothing
        norms = nothing 
    else 
        # If not standardizing, create pointers for the predictor matrices
        X = data.predictors.X
        Z = data.predictors.Z

        # Calculate the norm matrix
        # 2d array of norms corresponding to each coefficient
        norms = transpose(sum(X.^2, dims=1)).*sum(Z.^2, dims=1) 
    end

    # If chosen method is ista!/fista! with fixed step size and setStepsize is 
    # true, compute the step size:
    # if length(string(fun)) > 7 && (string(fun)[(end-7):end] == "istaNet!") && #to delete
    #    setStepsize == true
    if (string(fun) == "istaNet!" || string(fun) == "fistaNet!") && 
       setStepsize == true

        # Calculate and store transpose(X)*X
        XTX = transpose(X)*X
        # Calculate and store transpose(Z)*Z
        ZTZ = transpose(Z)*Z 
        
        # Step size is the reciprocal of the maximum eigenvalue of kron(Z, X)
        if isStandardize==true
            # Standardizing X and Z results in complex eigenvalues

            # Hack is to square the singular values to get the eigenvalues
            eig_X = (svd(XTX).S).^2
            eig_Z = (svd(ZTZ).S).^2

            stepsize = 1/max(maximum(eig_X) * maximum(eig_Z), 
                             minimum(eig_X) * minimum(eig_Z))
  	    else 
            stepsize = 1/max(eigmax(XTX) * eigmax(ZTZ),
                             eigmin(XTX) * eigmin(ZTZ))
        end
        
        println_verbose(string("Fixed step size set to ", stepsize), 
                        isVerbose) 
    end

    # Run the specified Elastic-net penalty method on the supplied inputs. 
    coeffs = mlmnet_pathwiseNet(fun, X, get_Y(data), Z, lambdas, alphas, regXidx, 
                             regZidx, reg, norms; isVerbose=isVerbose, 
                             stepsize=stepsize, funArgs...)

    # Perform the direct scaling transformation to undo double-shrinkage 
    # in the Naive Elastic-net solutions:
    if !isNaive
      for i in 1:length(alphas), j in 1:length(lambdas)
        lambdaL2 = lambdas[j]*(1-alphas[i])
        coeffs[:, :, j, i] *= (1+lambdaL2) #issue#10 ✓    
      end
    end

    # Back-transform coefficient estimates, if necessary. 
    # Case if including both X and Z intercepts:
    if isStandardize == true && (isXIntercept==true) && (isZIntercept==true)
        backtransform!(coeffs, meansX, meansZ, normsX, normsZ, get_Y(data),  # issue# should be backtransformNet!
                       data.predictors.X, data.predictors.Z)
    elseif isStandardize == true # Otherwise
        backtransformNet!(coeffs, isXIntercept, isZIntercept, meansX, meansZ, 
                       normsX, normsZ)
    end

    # lambdasL1 = lambdas.*alphas;
    # lambdasL2 = lambdas.*(1 .- alphas);

    # return MlmnetNet(coeffs, lambdas, alphas, lambdasL1, lambdasL2, data)
    return MlmnetNet(coeffs, lambdas, alphas, data)
  end





  """
  mlmnetNet(data, lambdas; 
         method, isXIntercept, isZIntercept, isXReg, isZReg, 
         isXInterceptReg, isZInterceptReg, isStandardize, isVerbose, 
         stepsize, setStepsize, funArgs...)

"""
function mlmnetNet(data::RawData, 
              lambdas::AbstractArray{Float64,1};
              method::String = "ista", 
              isNaive::Bool=false,
              isXIntercept::Bool=true, isZIntercept::Bool=true, 
              isXReg::BitArray{1}=trues(data.p), 
              isZReg::BitArray{1}=trues(data.q),     
              isXInterceptReg::Bool=false, isZInterceptReg::Bool=false, 
              isStandardize::Bool=true, isVerbose::Bool=true, 
              stepsize::Float64=0.01, setStepsize::Bool=true, 
              funArgs...)
  
  
  alphas = [1.0] # default LASSO, 𝛼 = 1

  rslts = mlmnetNet(data, lambdas, alphas; method,
                    isNaive, isXIntercept, isZIntercept, 
                    isXReg, isZReg,     
                    isXInterceptReg, isZInterceptReg, 
                    isStandardize, isVerbose, 
                    stepsize, setStepsize, 
                    funArgs...)
  
  return rslts
end


