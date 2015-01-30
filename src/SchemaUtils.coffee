global = @

# TODO(aramk) Move this to Objects utility.
# Adds support for using object arguments with _.memoize().
nextMemoizeObjKey = 1
memoizeObjectArg = (func) ->
  _.memoize func, (obj) ->
    key = obj._memoizeObjKey
    unless key?
      key = obj._memoizeObjKey = nextMemoizeObjKey++
    key

@SchemaUtils =

  getField: (fieldId, collection) -> collection.simpleSchema().schema(fieldId)

  getParameterField: (paramId) -> @getField(ParamUtils.addPrefix(paramId), Entities)

# Traverse the given schema and call the given callback with the field schema and ID.
  forEachFieldSchema: (schema, callback) ->
    fieldIds = schema._schemaKeys
    for fieldId in fieldIds
      fieldSchema = schema.schema(fieldId)
      if fieldSchema?
        callback(fieldSchema, fieldId)

  getSchemaReferenceFields: _.memoize(
    (collection) ->
      refFields = {}
      schema = collection.simpleSchema()
      SchemaUtils.forEachFieldSchema schema, (field, fieldId) ->
        if field.collectionType
          refFields[fieldId] = field
      refFields
    (collection) -> Collections.getName(collection)
  )

  getRefModifier: (model, collection, idMaps) ->
    modifier = {}
    $set = {}
    modifier.$set = $set
    refFields = @getSchemaReferenceFields(collection)
    _.each refFields, (field, fieldId) =>
      collectionName = Collections.getName(global[field.collectionType])
      # TODO(aramk) Refactor out logic for looking up fields in modifier format.
      oldId = @getModifierProperty(model, fieldId)
      newId = idMaps[collectionName][oldId]
      $set[fieldId] = newId
    modifier

  getParameterValue: (obj, paramId) ->
    # Allow paramId to optionally contain the prefix.
    paramId = ParamUtils.removePrefix(paramId)
    # Allow obj to contain "parameters" map or be the map itself.
    target = obj.parameters ? obj ?= {}
    @getModifierProperty(target, paramId)

  setParameterValue: (model, paramId, value) ->
    paramId = ParamUtils.removePrefix(paramId)
    target = model.parameters ?= {}
    @setModifierProperty(target, paramId, value)

  getParameterValues: (collection, paramId, args) ->
    args = _.extend({
      indexByValues: false
    }, args)
    values = {}
    _.each Collections.getItems(collection), (model) ->
      value = SchemaUtils.getParameterValue(model, paramId)
      if args.indexByValues
        models = values[value] ?= []
        models.push(model)
      else
        values[model._id] = value
    values

  # TODO(aramk) Move to objects util.
  getModifierProperty: (obj, property) ->
    target = obj
    segments = property.split('.')
    unless segments.length > 0
      return undefined
    for key in segments
      target = target[key]
      unless target?
        break
    target

  # TODO(aramk) Move to objects util.
  setModifierProperty: (obj, property, value) ->
    segments = property.split('.')
    unless segments.length > 0
      return false
    lastSegment = segments.pop()
    target = obj
    for key in segments
      target = target[key] ?= {}
    target[lastSegment] = value
    true

  # TODO(aramk) Move to objects util.
  unflattenParameters: (doc, hasParametersPrefix) ->
    Objects.unflattenProperties doc, (key) ->
      if !hasParametersPrefix or /^parameters\./.test(key)
        key.split('.')
      else
        null
    doc

  getDefaultParameterValues: memoizeObjectArg (collection) ->
    values = {}
    schema = collection.simpleSchema()
    SchemaUtils.forEachFieldSchema schema, (fieldSchema, paramId) ->
      # Default value is stored in the "classes" object to avoid being used by SimpleSchema.
      defaultValue = fieldSchema.classes?.ALL?.defaultValue
      if defaultValue?
        values[paramId] = defaultValue
    SchemaUtils.unflattenParameters(values, false)

  mergeDefaultParameterValues: (model, collection) ->
    defaults = @getDefaultParameterValues(collection)
    model.parameters ?= {}
    Setter.defaults(model.parameters, defaults.parameters)
    model

  findByProject: (collection, projectId) ->
    projectId ?= Projects.getCurrentId()
    if projectId
      collection.find({project: projectId})
    else
      throw new Error('Project ID not provided - cannot retrieve models.')

