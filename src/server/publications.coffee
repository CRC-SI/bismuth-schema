# Project collection is published by accounts-aurin.

Meteor.startup ->
  _.each [Typologies, Layers, Scenarios, Reports], (collection) ->
    collectionId = Collections.getName(collection)
    Meteor.publish collectionId, (projectId) ->
      unless projectId
        throw new Error('No project specified when subscribing.')
      collection.findByProject(projectId)

# Scenarios determine which entities are published.

Meteor.publish 'entities', (projectId, scenarioId) ->
  Entities.findByProjectAndScenario(projectId, scenarioId)

Meteor.publish 'userData', ->
  Meteor.users.find({}, {fields: {profile: 1, emails: 1, roles: 1, username: 1}})
