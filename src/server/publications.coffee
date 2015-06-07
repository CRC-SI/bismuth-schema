# Project collection is published by accounts-aurin.

Meteor.startup ->
  _.each [Typologies, Layers, Scenarios, Reports], (collection) ->
    collectionId = Collections.getName(collection)
    Meteor.publish collectionId, (projectId) ->
      ProjectUtils.authorizePublish.call @, projectId, -> collection.findByProject(projectId)

# Scenarios determine which entities are published.

Meteor.publish 'entities', (projectId, scenarioId) ->
  ProjectUtils.authorizePublish.call @, projectId, -> Entities.findByProjectAndScenario(projectId, scenarioId)

Meteor.publish 'userData', ->
  return [] unless @userId
  Meteor.users.find({}, {fields: {profile: 1, emails: 1, roles: 1, username: 1}})
