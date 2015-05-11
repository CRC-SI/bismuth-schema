Meteor.methods

  'scenarios/setup': (id, currentId) ->
    Promises.runSync -> ScenarioUtils.setup(id, currentId)

  'scenarios/remove': (id) ->
    Scenarios.remove(id)
    selector = {scenario: id}
    Entities.remove(selector)
