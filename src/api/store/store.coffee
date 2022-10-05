import { Time } from '../../utils/index.js'
import errors from '../core/errors.coffee'
import ID from '../core/ID.coffee'
import log from '../core/log.coffee'
import ratelimit from '../net/ratelimit.coffee'
import datasetExtractors from './dataset/extractors/index.js'
import datasetRoutes from './dataset/routes.coffee'
import datasetUpdaters from './dataset/updaters.coffee'
import interactionRoutes from './interaction/routes.coffee'
import interactionUpdaters from './interaction/updaters.coffee'

watchers = {}

notifyWatchers = (id) ->
	if watchers[id]
		for callback in watchers[id] then callback(cache[id])
		return watchers[id].length
	return 0
	
export watch = (id, callback) ->
	if !watchers[id] then watchers[id] = []
	watchers[id].push(callback)
	if cache[id] then callback(cache[id])
	return watchers[id].length

cache = {}

export clear = ->
	cache = {}
	watchers = {}

export load = (id) ->
	if not cache[id]
		reload(id)
		return true
	else if cache[id].loading
		return false
	else if cache[id].partial
		reload(id)
		return true

export loadWatch = (id, callback) ->
	load(id)
	watch(id, callback)

export preload = (id) ->
	if ratelimit.availableRPS > Number(localStorage['api.config.preload_threshold'])
		load(id)
		return true
	return false

reload = (id) ->
	route = datasetRoutes[ID.type(id)]
	if not route
		log({
			id,
			error: new errors.BadIDError({ id }),
			message: "unknown dataset type",
		})
		return Promise.resolve(null)
	startTime = Time.epochMs()
	setLoading(id)
	return route(...ID.varArray(id)[1..])
	.then (rawData) ->
		extract = datasetExtractors[ID.type(id)] ? datasetExtractors.GENERAL
		extract(rawData, id)
	.then (datasets) ->
		log({
			id,
			details: datasets.main.data,
			message: "#{Time.msToS(Time.epochMs() - startTime).toFixed(1)}s",
		})
		setData(id, datasets.main.data, datasets.main.partial)
		for dataset in datasets.sub
			if !cache[dataset.id] or (cache[dataset.id].partial is true) or !dataset.partial
				setData(dataset.id, dataset.data, dataset.partial)
		updater = datasetUpdaters[ID.type(id)]
		if updater
			targetID = updater.targetID(...ID.varArray(id)[1..])
			change = (target) -> updater.modify(target, datasets.main.data)
			setDataFromExisting(targetID, change)
	.catch (error) ->
		log({
			id,
			error,
			message: "load failed",
		})
		setError(id, error)
	.finally ->
		return cache[id]

setData = (id, data, partial = false) ->
	if !cache[id] then cache[id] = {}
	cache[id].asOf = Time.epochMs()
	cache[id].data = data
	cache[id].error = false
	cache[id].loading = false
	cache[id].partial = partial
	notifyWatchers(id)

setDataFromExisting = (id, change) ->
	rollback = change(cache[id].data)
	notifyWatchers(id)
	return rollback

setError = (id, error) ->
	if !cache[id] then cache[id] = {}
	cache[id].asOf = Time.epochMs()
	cache[id].data = null
	cache[id].error = error
	cache[id].loading = false
	cache[id].partial = false
	notifyWatchers(id)

setLoading = (id) ->
	if !cache[id] then cache[id] = {}
	cache[id].asOf = Time.epochMs()
	cache[id].loading = true
	notifyWatchers(id)

export submit = (id, payload) ->
	route = interactionRoutes[ID.type(id)]
	if not route
		log({
			id,
			error: new errors.BadIDError({ id }),
			message: "unknown interaction type",
		})
		return Promise.resolve(null)
	startTime = Time.epochMs()
	updater = interactionUpdaters[ID.type(id)]
	if updater
		targetID = updater.targetID(...ID.varArray(id)[1..])
		change = (target) -> updater.modify(target, payload)
		rollback = setDataFromExisting(targetID, change)
	return route(...ID.varArray(id)[1..])(payload)
	.then (rawData) ->
		log({
			id,
			details: { payload, response: rawData },
			message: "#{Time.msToS(Time.epochMs() - startTime).toFixed(1)}s",
		})
		setData(id, rawData)
	.catch (error) ->
		log({
			id,
			details: { payload },
			error,
			message: "send failed",
		})
		setError(id, error)
		if rollback
			setDataFromExisting(targetID, rollback)
	.finally ->
		return cache[id]