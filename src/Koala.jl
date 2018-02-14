__precompile__()
module Koala

# new: 
export @more, keys_ordered_by_values, bootstrap_resample_of_mean, params
export load_boston, load_ames, datanow
export fit!, predict, rms, rmsl, err
export SupervisedMachine, ConstantRegressor
export splitrows, learning_curve

# for use in this module:
import DataFrames: DataFrame, AbstractDataFrame, names
import CSV
import StatsBase: sample

# constants:
const COLUMN_WIDTH = 24 # for displaying dictionaries with `showall`
const srcdir = dirname(@__FILE__) # the full path for this file

# functions to be extended (provided methods) in dependent packages:
function fit end
function predict end
function setup end
function get_metadata end
function transform end
function inverse_transform end
function get_scheme_X end
function get_schme_y end
function fit! end


## Some general assorted helpers:

""" macro shortcut for showing all of last REPL expression"""
macro more()
    esc(quote
        showall(Main.ans)
    end)
end

"""Load a well-known public regression dataset with nominal features."""
function load_boston()
    df = CSV.read(joinpath(srcdir, "data", "Boston.csv"))
    features = filter(names(df)) do f
        f != :MedV
    end
    X = df[features] 
    y = df[:MedV]
    return X, y 
end

"""Load a reduced version of the well-known Ames Housing dataset,
having six numerical and six categorical features."""
function load_ames()
    df = CSV.read(joinpath(srcdir, "data", "reduced_ames.csv"))
    features = filter(names(df)) do f
        f != :target
    end
    X = df[features] 
    y = exp.(df[:target])
    return X, y 
end
datanow=load_ames

""" `showall` method for dictionaries with markdown format"""
function Base.showall(stream::IO, d::Dict)
    print(stream, "\n")
    println(stream, "key                     | value")
    println(stream, "-"^COLUMN_WIDTH * "|" * "-"^COLUMN_WIDTH)
    kys = keys(d) |> collect |> sort
    for k in kys
        key_string = string(k)*" "^(max(0,COLUMN_WIDTH - length(string(k))))
        println(stream, key_string * "|" * string(d[k]))
    end
end

function keys_ordered_by_values(d::Dict{T,S}) where {T, S<:Real}

    items = collect(d) # 1d array containing the (key, value) pairs
    sort!(items, by=pair->pair[2], alg=QuickSort)

    return T[pair[1] for pair in items]

end

"""
## `bootstrap_resample_of_mean(v; n=10^6)`

Returns a vector of `n` estimates of the mean of the distribution
generating the samples in `v` from `n` bootstrap resamples of `v`.

"""
function bootstrap_resample_of_mean(v; n=10^6)

    n_samples = length(v)
    mu = mean(v)

    simulated_means = Array{Float64}(n)

    for i in 1:n
        pseudo_sample = sample(v, n_samples, replace=true)
        simulated_means[i]=mean(pseudo_sample)
    end
    return simulated_means
end


## `BaseType` - base type for external `Koala` structs in dependent packages.  

abstract type BaseType end

""" Return a dictionary of values keyed on the fields of specified object."""
function params(object::BaseType)
    value_given_parameter  = Dict{Symbol,Any}()
    for name in fieldnames(object)
        if isdefined(object, name)
            value_given_parameter[name] = getfield(object,name)
        else
            value_given_parameter[name] = "undefined"
        end 
    end
    return value_given_parameter
end

""" Extract type parameters of the type of an object."""
function type_parameters(object)
    params = typeof(object).parameters
    ret =[]
    for p in params
        if isa(p, Type)
            push!(ret, p.name.name)
        else
            push!(ret, p)
        end
    end
    return ret
end

""" Output plain/text representation to specified stream. """
function Base.show(stream::IO, object::BaseType)
    abbreviated(n) = "..."*string(n)[end-2:end]
    type_params = type_parameters(object)
    if isempty(type_params)
        type_string = ""
    else
        type_string = string("{", ["$T," for T in type_params]..., "}")
    end
    print(stream, string(typeof(object).name.name,
                         type_string,
                         "@", abbreviated(hash(object))))
end

""" Output detailed plain/text representation to specified stream. """
function Base.showall(stream::IO, object::BaseType)
    show(stream, object)
    println(stream)
    showall(stream, params(object))
end


## Abstract model and machine types

# "models" simply store algorithm hyperparameters (eg, a
# regularization parameter); "machines" wrap models, data,
# transformation rules ("schemes") and predictors together.

abstract type Model <: BaseType end 

# supervised model types are collected together according to their
# corresponding predictor type, `P`:
abstract type SupervisedModel{P} <: Model end

# so, for example, we later prescribe `ConstantRegressor <: SupervisedModel{Float64}`

abstract type Regressor{P} <: SupervisedModel{P} end
abstract type Classifier{P} <: SupervisedModel{P} end 

abstract type Machine <: BaseType end


## Loss and lower-interface error functions

function rms(y, yhat, rows)
    length(y) == length(yhat) || throw(DimensionMismatch())
    ret = 0.0
    for i in rows
        ret += (y[i] - yhat[i])^2
    end
    return sqrt(ret/length(rows))
end

function rms(y, yhat)
    length(y) == length(yhat) || throw(DimensionMismatch())
    ret = 0.0
    for i in eachindex(y)
        ret += (y[i] - yhat[i])^2
    end
    return sqrt(ret/length(y))
end

function rmsl(y, yhat, rows)
    length(y) == length(yhat) || throw(DimensionMismatch())
    ret = 0.0
    for i in rows
        ret += (log(y[i]) - log(yhat[i]))^2
    end
    return sqrt(ret/length(rows))
end

function rmsl(y, yhat)
    length(y) == length(yhat) || throw(DimensionMismatch())
    ret = 0.0
    for i in eachindex(y)
        ret += (log(y[i]) - log(yhat[i]))^2
    end
    return sqrt(ret/length(y))
end

function err(rgs::Regressor, predictor, X, y, rows,
             parallel, verbosity, loss::Function=rms)
    return loss(y[rows], predict(rgs, predictor, X, rows, parallel, verbosity))
end

function err(rgs::Regressor, predictor, X, y,
             parallel, verbosity, loss::Function=rms)
    return loss(y, predict(rgs, predictor, X, parallel, verbosity))
end

mutable struct SupervisedMachine{P, M <: SupervisedModel{P}} <: Machine

    model::M
    metadata
    scheme_X
    scheme_y
    n_iter::Int
    Xt
    yt
    predictor::P
    report
    cache

    function SupervisedMachine{P, M}(
        model::M,
        X::AbstractDataFrame,
        y::AbstractVector,
        train_rows::AbstractVector{Int};
        features = Symbol[]) where {P, M <: SupervisedModel{P}}

        # check dimension match:
        size(X,1) == length(y) || throw(DimensionMismatch())

        # check valid `features`; if empty take all
        if isempty(features)
            features = names(X)
        end
        allunique(features) || error("Duplicate features.")
        issubset(Set(features), Set(names(X))) || error("Invalid feature vector.")

        ret = new{P, M}(model::M)
        ret.metadata = get_metadata(model, X, y, train_rows, features)
        ret.scheme_X = get_scheme_X(model, X, train_rows, features)
        ret.scheme_y = get_scheme_y(model, y, train_rows)
        ret.n_iter = 0
        ret.Xt = transform(model, ret.scheme_X, X)
        ret.yt = transform(model, ret.scheme_y, y)
        ret.report = Dict{Symbol,Any}()

        return ret
    end

end

function SupervisedMachine(model::M, X, y, train_rows; args...) where {P, M <: SupervisedModel{P}}
    return SupervisedMachine{P, M}(model, X, y, train_rows; args...)
end

function Base.show(stream::IO, mach::SupervisedMachine)
    abbreviated(n) = "..."*string(n)[end-2:end]
    type_string = string("{", mach.model, "}")
    print(stream, string(typeof(mach).name.name,
                         type_string,
                         "@", abbreviated(hash(mach))))
end


function Base.showall(stream::IO, mach::SupervisedMachine)
    show(stream, mach)
    println(stream)
    dict = params(mach)
    report_items = sort(collect(keys(dict[:report])))
    dict[:report] = "Dict with keys: $report_items"
    dict[:Xt] = string(typeof(mach.Xt), " of shape ", size(mach.Xt))
    dict[:yt] = string(typeof(mach.yt), " of shape ", size(mach.yt))
    dict[:metadata] = string("Object of type $(typeof(mach.metadata))")
    delete!(dict, :cache)
    showall(stream, dict)
    println(stream)
    showall(stream, mach.model)
end

function fit!(mach::SupervisedMachine, rows;
              add=false, verbosity=1, parallel=true, args...)
    if !add
        mach.n_iter = 0
    end
    if  mach.n_iter == 0 
        mach.cache = setup(mach.model, mach.Xt, mach.yt, rows, mach.metadata,
                           parallel, verbosity)
    end
    mach.predictor, report, mach.cache =
        fit(mach.model, mach.cache, add, parallel, verbosity; args...)
    merge!(mach.report, report)
    if isdefined(mach.model, :n)
        mach.n_iter += mach.model.n
    else
        mach.n_iter = 1
    end
    return mach
end

function predict(mach::SupervisedMachine, X, rows; parallel=true, verbosity=1)
    mach.n_iter > 0 || error(string(mach, " has not been fitted."))
    Xt = transform(mach.model, mach.scheme_X, X[rows,:])
    yt = predict(mach.model, mach.predictor, Xt, parallel, verbosity)
    return inverse_transform(mach.model, mach.scheme_y, yt)
end

function predict(mach::SupervisedMachine, X; parallel=true, verbosity=1)
    mach.n_iter > 0 || error(string(mach, " has not been fitted."))
    Xt = transform(mach.model, mach.scheme_X, X)
    yt = predict(mach.model, mach.predictor, Xt, parallel, verbosity)
    return inverse_transform(mach.model, mach.scheme_y, yt)
end

function err(mach::SupervisedMachine, test_rows;
             loss=rms, parallel=false, verbosity=0, raw=false)

    # transformed version of target predictions:
    raw_predictions = predict(mach.model, mach.predictor, mach.Xt, test_rows,
                            parallel, verbosity) 

    if raw # return error on *transformed* target, which is faster
        return loss(raw_predictions, mach.yt[test_rows])
    else  # return error for untransformed target
        return loss(inverse_transform(mach.model, mach.scheme_y, raw_predictions),
                    inverse_transform(mach.model, mach.scheme_y, mach.yt[test_rows]))
    end
end


## `SupervisedModel`  fall-back methods

get_metadata(model::SupervisedModel, X::AbstractDataFrame, y,
             rows, features) = features

setup(model::SupervisedModel, Xt, yt, rows, metadata, parallel, verbosity) =
    setup(model, Xt[rows,:], yt[rows], metadata, parallel, verbosity) 

predict(model::SupervisedModel, predictor, Xt, rows, parallel, verbosity) =
    predict(model, predictor, Xt[rows,:], parallel, verbosity)


## `ConstantRegressor` 

# to test iterative methods, we give the following simple regressor
# model a "bogus" field for counting the number of iterations (which
# make no difference to predictions):
mutable struct ConstantRegressor <: Regressor{Float64}
    n::Int 
end

ConstantRegressor() = ConstantRegressor(1)

get_scheme_X(model::ConstantRegressor, X, train_rows, features) = features

get_scheme_y(model::ConstantRegressor, y, train_rows) = nothing

transform(model::ConstantRegressor, features, X) = X[features]

transform(model::ConstantRegressor, no_thing::Void, y) = y

inverse_transform(model::ConstantRegressor, no_thing::Void, yt) = yt

function setup(rgs::ConstantRegressor, X, y, metadata, parallel, verbosity)
    return mean(y)
end
    
function fit(rgs::ConstantRegressor, cache, add, parallel, verbosity)
    predictor = cache
    report = Dict{Symbol, Any}()
    report[:mean] = predictor 
    return predictor, report, cache
end

function predict(rgs::ConstantRegressor, predictor, X, parallel, verbosity)
    return  Float64[predictor for i in 1:size(X,1)]
end


## Validation methods

"""
## splitrows(rows, fractions...)

Assumes (but does not check) that `collect(rows)` has integer
eltype. Then splits rows into a tuple of `Vector{Int}` objects whose
lengths are given by the corresponding `fractions` of
`length(rows)`. The last fraction is not actually be provided, as
it is inferred from the preceding ones. So, for example,

    julia> splitrows(1:1000, 0.2, 0.7)
    (1:200, 201:900, 901:1000)

"""
function splitrows(rows, fractions...)
    rows = collect(rows)
    rowss = []
    if sum(fractions) >= 1
        throw(DomainError)
    end
    n_patterns = length(rows)
    first = 1
    for p in fractions
        n = round(Int, p*n_patterns)
        n == 0 ? (Base.warn("Rows with only one element"); n = 1) : nothing
        push!(rowss, rows[first:(first + n - 1)])
        first = first + n
    end
    if first > n_patterns
        Base.warn("Last vector in split has only one element.")
        first = n_patterns
    end
    push!(rowss, rows[first:n_patterns])
    return tuple(rowss...)
end

function learning_curve(mach::SupervisedMachine, test_rows,
                        range; restart=true, loss=rms, raw=true, parallel=true,
                        verbosity=1, fit_args...) 

    isdefined(mach.model, :n) || error("$(mach.model) does not support iteration.")

    # save to be reset at end:
    old_n = mach.model.n
    
    raw || warn("Reporting errors for *transformed* data. Use `raw=false` "*
                 " to report true errors.")
    
    range = collect(range)
    sort!(range)
    
    if restart
        mach.n_iter=0
        mach.cache = setup(mach.model, mach.Xt, mach.yt, mach.metadata,
                           parallel, verbosity - 1) 
    end

    n_iter_list = Float64[]
    errors = Float64[]

    filter!(range) do x
        x > mach.n_iter
    end

    while !isempty(range)
        verbosity < 1 || print("\rNext iteration number: ", range[1]) 
        # set number of iterations for `fit` call:
        mach.model.n = range[1] - mach.n_iter
        mach.predictor, report, mach.cache =
            fit(mach.model, mach.cache, true, parallel, verbosity - 1; fit_args...)
        mach.n_iter += mach.model.n
        push!(n_iter_list, mach.n_iter)
        push!(errors, err(mach, test_rows, raw=raw, loss=loss))
        filter!(range) do x
            x > mach.n_iter
        end
    end

    verbosity < 1 || println("\nLearning curve added to machine report.")
    
    mach.report[:learning_curve] = (n_iter_list, errors)
    
    mach.model.n = old_n
    
    return n_iter_list, errors

end

# function cv(mach:SupervisedMachine, test_rows;
#              n_folds=9, loss=rms, parallel=true, verbosity=0, raw=false)


end # module