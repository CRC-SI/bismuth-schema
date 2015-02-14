Depends.define 'Entities',
  ['EntitySchema', 'Projects', 'SchemaUtils', 'Typologies', 'Units'],
  (EntitySchema, Projects, SchemaUtils, Typologies, Units) ->

    Collections.ready ->
      Entities = new Meteor.Collection 'entities'
      Entities.attachSchema(EntitySchema)
      Entities.ParametersSchema = EntitySchema.ParametersSchema
      Entities.allow(Collections.allowAll())

      Entities.resolveTypeId = (type) -> type.toLowerCase().replace(/\s+/g, '_')

      Entities.findByProject = (projectId) -> SchemaUtils.findByProject(Entities, projectId)

      Entities.findByProjectAndScenario = (projectId, scenarioId) ->
        # NOTE: Always use Entities.findByProject() for a cursor on all entities as scenarios are
        # switched. Entities.findByProjectAndScenario() should only be used for publishing or when
        # repeated calls are possible. If a single call is made when no scenario exists, the
        # returned cursor won't be updated with entities in scenarios.
        projectId ?= Projects.getCurrentId()
        unless projectId
          throw new Error('Project ID not provided - cannot retrieve models.')
        # Only entities of the current scenario (if any) or the baseline project should be returned.
        if scenarioId
          Entities.find({scenario: scenarioId, project: projectId})
        else
          Entities.find({scenario: {$exists: false}, project: projectId})

      Entities.findByTypology = (typologyId) -> Entities.find({typology: typologyId})

      Entities.getInputNames = (collection) ->
        entities = Collections.getItems(collection)
        allInputs = {}
        _.each entities, (entity) ->
          _.each entity.parameters.inputs, (value, key) ->
            allInputs[key] = true
        Object.keys(allInputs)

      Entities.getChildren = (parentId) -> Entities.find({parent: parentId})

      Entities.getFlattened = (id) ->
        entity = Entities.findOne(id)
        Entities.mergeTypology(entity)
        entity

      Entities.getAllFlattenedInProject = (filter) ->
        entities = Entities.findByProject().fetch()
        if filter
          entities = _.filter entities, filter
        _.map entities, (entity) -> Entities.getFlattened(entity._id)

      Entities.mergeTypology = (entity) ->
        typologyId = entity.typology
        if typologyId?
          typology = Typologies.findOne(typologyId)
          Entities.mergeTypologyObj(entity, typology)
        entity

      Entities.mergeTypologyObj = (entity, typology) ->
        if typology?
          entity._typology = typology
          SchemaUtils.mergeDefaultParameterValues(typology, Typologies)
          entity.parameters ?= {}
          Setter.defaults(entity.parameters, typology.parameters)
          Typologies.filterParameters(entity)
        entity

      return Entities
