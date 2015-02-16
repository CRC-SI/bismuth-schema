Typologies = new Meteor.Collection 'typologies'
Typologies.attachSchema(TypologySchema)
Typologies.ParametersSchema = TypologySchema.ParametersSchema
Typologies.allow(Collections.allowAll())
Typologies.findByProject = (projectId) -> SchemaUtils.findByProject(Typologies, projectId)
Typologies.findByName = (name, projectId) ->
  projectId = projectId ? Projects.getCurrentId()
  Typologies.findOne({name: name, project: projectId})

################################################################################################
# ASSOCIATION MAINTENANCE
################################################################################################

Typologies.after.remove (userId, typology) ->
  # Remove entities when the typology is removed.
  _.each Entities.findByTypology(typology._id).fetch(), (entity) ->
    Entities.remove(entity._id)

################################################################################################
# TYPOLOGY COLORS
################################################################################################

TypologyColors = ['#8dd3c7', '#ffffb3', '#bebada', '#fb8072', '#80b1d3', '#fdb462', '#b3de69',
    '#fccde5', '#d9d9d9', '#bc80bd', '#ccebc5', '#a6cee3', '#1f78b4', '#b2df8a', '#33a02c',
    '#fb9a99', '#e31a1c', '#fdbf6f', '#ff7f00', '#cab2d6', '#6a3d9a', '#ffff99']

Typologies.getNextAvailableColor = (projectId, options) ->
  options = _.extend({
    exclude: []
  }, options)
  typologyColorMap = {}
  Typologies.findByProject(projectId).forEach (typology) ->
    color = SchemaUtils.getParameterValue(typology, 'style.fill_color')
    if color
      typologyColorMap[color] = typology._id
  usedColors = Object.keys(typologyColorMap)
  availableColors = _.difference(TypologyColors, usedColors, options.exclude)
  unless availableColors.length == 0
    availableColors[0]
  else
    Colors.getRandomColor()
