############################################
################ Structures ################ 
############################################

function is_glb(potential_glb, models)
    for model in models
        if !(potential_glb <: input_scitype(model))
            return false
        end
    end
    return true
end

function glb(models)
    for model in models
        potential_glb = input_scitype(model)
        if is_glb(potential_glb, models)
            return potential_glb
        end
    end
    return Unknown
end


mutable struct DeterministicStack{modelnames, input_scitype, target_scitype} <: DeterministicComposite
   models::NTuple{<:Any, Supervised}
   metalearner::Deterministic
   cv_strategy::Union{CV, StratifiedCV} 
   function DeterministicStack(modelnames, models, metalearner, cv_strategy)
        target_scitype = MMI.target_scitype(metalearner)
        input_scitype = glb(models)
        return new{modelnames, input_scitype, target_scitype}(models, metalearner, cv_strategy)
   end
end

mutable struct ProbabilisticStack{modelnames, input_scitype, target_scitype} <: ProbabilisticComposite
    models::NTuple{<:Any, Supervised}
    metalearner::Probabilistic
    cv_strategy::Union{CV, StratifiedCV} 
    function ProbabilisticStack(modelnames, models, metalearner, cv_strategy)
        target_scitype = MMI.target_scitype(metalearner)
        input_scitype = glb(models)
        return new{modelnames, input_scitype, target_scitype}(models, metalearner, cv_strategy)
    end
 end


const Stack{modelnames, input_scitype, target_scitype} = 
    Union{DeterministicStack{modelnames, input_scitype, target_scitype}, 
            ProbabilisticStack{modelnames, input_scitype, target_scitype}}

"""
    Stack(;metalearner=nothing, cv_strategy=CV(), named_models...)

Implements the generalized Stack algorithm introduced by Wolpert 
in https://www.sciencedirect.com/science/article/abs/pii/S0893608005800231 and 
generalized by Van der Laan et al in https://biostats.bepress.com/ucbbiostat/paper222/.


We currently provide two different stack types the `DeterministicStack` and the `ProbabilisticStack`.
The type of which is automatically chosen by the constructor based on the provided metalearner.

# Arguments
- `metalearner::Model`: The model that will optimize the desired criterion based on its internals. 
                        For instance, a LinearRegression model will optimize the squared error.
- `cv_strategy::Union{CV, StratifiedCV}`: The resampling strategy used to train the metalearner.
- `named_models`: The models that will be part of the library

# Example

Let's build a simple DeterministicStack.

```julia
using MLJBase
using EvoTrees
using MLJLinearModels

X, y = make_regression(500, 5)

stack = Stack(;metalearner=LinearRegressor(),
                cv_strategy=CV(),
                evo_2=EvoTreeRegressor(max_depth=2), 
                evo_3=EvoTreeRegressor(max_depth=3),
                lr=LinearRegressor())

mach = machine(stack, X, y)
evaluate!(mach; resampling=CV(), measure=rmse)
```

"""
function Stack(;metalearner=nothing, cv_strategy=CV(), named_models...)
    metalearner === nothing && throw(ArgumentError("metalearner argument should be overrided"))

    nt = NamedTuple(named_models)
    modelnames = keys(nt)
    models = values(nt)

    if metalearner isa Deterministic
        stack =  DeterministicStack(modelnames, models, metalearner, cv_strategy)
    elseif metalearner isa Probabilistic
        stack = ProbabilisticStack(modelnames, models, metalearner, cv_strategy)
    else
        throw(ArgumentError("The metalearner should be a subtype 
                    of $(Union{Deterministic, Probabilistic})"))
    end
    MMI.clean!(stack)

    return stack
end


function MMI.clean!(stack::Stack)
    # We only carry checks and don't try to correct the arguments here
    message = ""

    target_scitype(stack.metalearner) <: Union{AbstractArray{<:Continuous}, AbstractArray{<:Finite}} ||
        throw(ArgumentError("The metalearner should have target_scitype: 
                $(Union{AbstractArray{<:Continuous}, AbstractArray{<:Finite}})"))

    return message
end


Base.propertynames(::Stack{modelnames, <:Any, <:Any}) where modelnames = tuple(:cv_strategy, :metalearner, :models, modelnames...)


function Base.getproperty(stack::Stack{modelnames, <:Any, <:Any}, name::Symbol) where modelnames
    name === :metalearner && return getfield(stack, :metalearner)
    name === :cv_strategy && return getfield(stack, :cv_strategy)
    name === :models && return getfield(stack, :models)
    models = getfield(stack, :models)
    for j in eachindex(modelnames)
        name === modelnames[j] && return models[j]
    end
    error("type Stack has no field $name")
end


MMI.target_scitype(::Type{<:Stack{modelnames, input_scitype, target_scitype}}) where 
    {modelnames, input_scitype, target_scitype} = target_scitype


MMI.input_scitype(::Type{<:Stack{modelnames, input_scitype, target_scitype}}) where 
    {modelnames, input_scitype, target_scitype} = input_scitype



###########################################################
################# Node operations Methods ################# 
###########################################################


function getfolds(y::AbstractNode, cv::CV, n::Int)
    folds = source(train_test_pairs(cv, 1:n))
end


function getfolds(y::AbstractNode, cv::StratifiedCV, n::Int)
    node(YY->train_test_pairs(cv, 1:n, YY), y)
end


function trainrows(X::AbstractNode, folds::AbstractNode, nfold)
    node((XX, ff) -> selectrows(XX, ff[nfold][1]), X, folds)
end


function testrows(X::AbstractNode, folds::AbstractNode, nfold)
    node((XX, ff) -> selectrows(XX, ff[nfold][2]), X, folds)
end


pre_judge_transform(ŷ::Node, ::Type{<:Probabilistic}, ::Type{<:AbstractArray{<:Finite}}) = 
    node(ŷ->pdf.(ŷ, levels.(ŷ)), ŷ)

pre_judge_transform(ŷ::Node, ::Type{<:Probabilistic}, ::Type{<:AbstractArray{<:Continuous}}) = 
    node(ŷ->mean.(ŷ), ŷ)

pre_judge_transform(ŷ::Node, ::Type{<:Deterministic}, ::Type{<:AbstractArray{<:Continuous}}) = 
    ŷ

#######################################
################# Fit ################# 
#######################################
"""
    fit(m::Stack, verbosity::Int, X, y)
"""
function fit(m::Stack, verbosity::Int, X, y)
    n = nrows(y)

    X = source(X)
    y = source(y)

    Zval = []
    yval = []

    folds = getfolds(y, m.cv_strategy, n)
    # Loop over the cross validation folds to build a training set for the metalearner.
    for nfold in 1:m.cv_strategy.nfolds
        Xtrain = trainrows(X, folds, nfold)
        ytrain = trainrows(y, folds, nfold)
        Xtest = testrows(X, folds, nfold)
        ytest = testrows(y, folds, nfold)
        
        # Train each model on the train fold and predict on the validation fold
        # predictions are subsequently used as an input to the metalearner
        Zfold = []
        for model in m.models
            mach = machine(model, Xtrain, ytrain)
            ypred = predict(mach, Xtest)
            # Dispatch the computation of the expected mean based on 
            # the model type and target_scytype
            ypred = pre_judge_transform(ypred, typeof(model), target_scitype(model))
            push!(Zfold, ypred)
        end

        Zfold = hcat(Zfold...)
        
        push!(Zval, Zfold)
        push!(yval, ytest)
    end

    Zval = MLJBase.table(vcat(Zval...))
    yval = vcat(yval...)

    metamach = machine(m.metalearner, Zval, yval)

    # Each model is retrained on the original full training set
    Zpred = []
    for model in m.models
        mach = machine(model, X, y)
        ypred = predict(mach, X)
        ypred = pre_judge_transform(ypred, typeof(model), target_scitype(model))
        push!(Zpred, ypred)
    end

    Zpred = MLJBase.table(hcat(Zpred...))
    ŷ = predict(metamach, Zpred)

    # We can infer the Surrogate by two calls to supertype
    mach = machine(supertype(supertype(typeof(m)))(), X, y; predict=ŷ)

    return!(mach, m, verbosity)

end

