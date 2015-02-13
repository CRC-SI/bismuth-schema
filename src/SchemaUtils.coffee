global = @

Depends.define 'SchemaUtils', =>

  # TODO(aramk) Move this to Objects utility.
  # Adds support for using object arguments with _.memoize().
  nextMemoizeObjKey = 1
  memoizeObjectArg = (func) ->
    _.memoize func, (obj) ->
      key = obj._memoizeObjKey
      unless key?
        key = obj._memoizeObjKey = nextMemoizeObjKey++
      key

  SchemaUtils =

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

    extendSchema: (orig, changes) -> _.extend({}, orig, changes)

    autoLabel: (field, id) ->
      label = field.label
      if label?
        label
      else
        label = id.replace('_', '')
        Strings.toTitleCase(label)

    createCategorySchemaObj: (cat, catId, args) ->
      catSchemaFields = {}
      hasRequiredField = false
      _.each cat.items, (item, itemId) =>
        if item.items?
          result = @createCategorySchemaObj(item, itemId, args)
          if result.hasRequiredField
            hasRequiredField = true
          fieldSchema = result.schema
        else
          # Required fields must explicitly specify "optional" as false.
          fieldSchema = _.extend({optional: true}, args.itemDefaults, item)
          if fieldSchema.optional == false
            hasRequiredField = true
          @autoLabel(fieldSchema, itemId)
          # If defaultValue is used, put it into "classes" to prevent SimpleSchema from storing this
          # value in the doc. We want to inherit this value at runtime for all classes, but not
          # persist it in multiple documents in case we want to change it later in the schema.
          defaultValue = fieldSchema.defaultValue
          if defaultValue?
            classes = fieldSchema.classes ?= {}
            allClassOptions = classes.ALL ?= {}
            # TODO(aramk) This block causes a strange issue where ALL.classes is defined with
            # defaultValue already set, though it wasn't a step earlier...
            if allClassOptions.defaultValue?
              throw new Error('Default value specified on field ' + itemId +
                  ' and in classOptions - only use one.')
            allClassOptions.defaultValue = defaultValue
            delete fieldSchema.defaultValue
        catSchemaFields[itemId] = fieldSchema
      catSchema = new SimpleSchema(catSchemaFields)
      catSchemaArgs = _.extend({
        # If a single field is required, the entire category is marked required. If no fields are
        # required, the category can be omitted.
        optional: !hasRequiredField
      }, args.categoryDefaults, cat, {type: catSchema})
      @autoLabel(catSchemaArgs, catId)
      delete catSchemaArgs.items
      {hasRequiredField: hasRequiredField, schema: catSchemaArgs}

    # Constructs SimpleSchema fields which contains all categories and each category is it's own
    # SimpleSchema.
    createCategoriesSchemaFields: (args) ->
      args ?= {}
      cats = args.categories
      unless cats
        throw new Error('No categories provided.')
      # For each category in the schema.
      catsFields = {}
      for catId, cat of cats
        result = @createCategorySchemaObj(cat, catId, args)
        catsFields[catId] = result.schema
      catsFields

    createCategoriesSchema: (args) -> new SimpleSchema(@createCategoriesSchemaFields(args))

    forEachCategoryField: (category, callback) ->
      for itemId, item of category.items
        if item.items?
          @forEachCategoryField(item, callback)
        else
          callback(itemId, item, category)

    forEachCategoriesField: (categories, callback) ->
      for catId, category of categories
        @forEachCategoryField(category, callback)

    mergeObjectsWithTemplate: (args) ->
      template = args.template
      result = {}
      _.map args.items, (item, itemId) ->
        result[itemId] = Setter.merge(Setter.clone(template), item)
      result

    mergeDefaultsWithTemplate: (args) ->
      items = args.items
      _.each items, (value, key) ->
        items[key] = {defaultValue: value}
      @mergeObjectsWithTemplate(args)

    ################################################################################################
    # COMMON SCHEMA DEFINITION
    ################################################################################################

    descSchema: ->
      label: 'Description'
      type: String

    projectSchema: ->
      label: 'Project'
      type: String
      index: true
      collectionType: 'Projects'

    heightSchema: ->
      type: Number
      decimal: true
      desc: 'Maximum height of the entity (excluding elevation).'
      units: Units.m

    elevationSchema: ->
      type: Number
      decimal: true
      desc: 'Elevation from ground-level to the base of this entity.'
      units: Units.m

    calcArea: (id) ->
      feature = AtlasManager.getEntity(id)
      if feature
        target = feature.getForm('footprint')
        unless target
          target = feature.getForm('mesh')
        unless target
          throw new Error('GeoEntity was found but no footprint or mesh exists - cannot ' +
            'calculate area.')
        target.getArea()
      else
        throw new Error('GeoEntity not found - cannot calculate area.')

    calcLength: (id) ->
      feature = AtlasManager.getEntity(id)
      line = feature.getForm('line')
      unless line
        throw new Error('Cannot calculate length of non-line GeoEntity with ID ' + id)
      line.getLength()

    areaSchema: ->
      label: 'Area'
      type: Number
      desc: 'Area of the land parcel.'
      decimal: true
      units: Units.m2
      calc: -> @calcArea(@model._id)

####################################################################################################
# SCHEMA OPTIONS
####################################################################################################

SimpleSchema.debug = true
SimpleSchema.extendOptions
# Optional extra fields.
  desc: Match.Optional(String)
  units: Match.Optional(String)
# Used on reference fields containing IDs of models in the given collection type.
  collectionType: Match.Optional(String)
# An expression for calculating the value of the given field for the given model. These are output
# fields and do not appear in forms. The formula can be a string containing other field IDs prefixed
# with '$' (e.g. $occupants) which are resolved to the local value per model, or global parameters
# if no local equivalent is found. If the expression is a function, it is passed the current model
# and the field and should return the result.
  calc: Match.Optional(Match.Any)
# A map of class names to objects of properties. "defaultValues" specifies the default value for
# the given class.
  classes: Match.Optional(Object)
