Depends.define 'ParamUtils', ['Entities', 'Projects'], (Entities, Projects) ->

  ParamUtils =
    
    _prefix: 'parameters'
    _rePrefix: /^parameters\./

    addPrefix: (id) ->
      if @_rePrefix.test(id)
        id
      else
        @_prefix + '.' + id
    
    removePrefix: (id) -> id.replace(@_rePrefix, '')
    
    hasPrefix: (id) -> @._rePrefix.test(id)
    
    getParamSchema: (paramId) ->
      paramId = @removePrefix(paramId)
      Entities.ParametersSchema.schema(paramId) ? Projects.ParametersSchema.schema(paramId)
    
    getLabel: (paramId) ->
      schema = @getParamSchema(paramId)
      label = schema.label
      return label if label?
      label = _.last(paramId.split('.'))
      Strings.toTitleCase(Strings.toSpaceSeparated(label))

    getNumberFormatter: _.once ->
      df = Q.defer()
      require ['atlas/util/NumberFormatter'], (NumberFormatter) ->
        formatter = new NumberFormatter()
        df.resolve(formatter)
      df.promise

    getParamNumberFormatter: _.memoize (paramId) ->
      paramSchema = @getParamSchema(paramId)
      unless paramSchema.type == Number
        df.resolve(null)
        return df.promise
      decimalPoints = paramSchema.decimalPoints ? 2
      @getNumberFormatter().then (formatter) ->
        format = (value) ->
          formatter.round(value, {minSigFigs: decimalPoints, maxSigFigs: decimalPoints})
        format
