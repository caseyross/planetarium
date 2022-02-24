# Separate and extract independent Reddit entities from raw API data.
# Primarily useful to parse Reddit's "Listing" and "Thing" data structures, and to flatten comment trees for store ingestion.
# All extractors return the same data structure. It is described below as it is constructed.
# NOTE: Contains side effects throughout (namely, input data modification).
export default extract = (rawData) ->
	result =
		main: null # The object specified by an API route.
		sub: [] # Objects contained in the same API response as the main objects, but which "belong" to a different API route.
	switch rawData.kind
		when 'Listing'
			listing = rawData.data.children
			if !Array.isArray(listing) then listing = []
			# If each top-level object in the listing is referenceable by ID, the primary data becomes simply an array of IDs.
			# If not, the primary data contains the full child objects.
			listingDatasets = listing.map((item) -> extract(item))
			childIds = listingDatasets.map(({ main }) -> main.id)
			if childIds.every((id) -> id?)
				result.main =
					id: null # At the top level of the API response, we don't need this, as we already know which ID the data was requested for... (continues in comment extraction)
					data: childIds
				result.sub = listingDatasets.flatMap(({ main, sub }) -> sub.concat(main))
			else
				result.main =
					id: null
					data: listingDatasets.map(({ main }) -> main)
				result.sub = listingDatasets.flatMap(({ sub }) -> sub)
		when 't1'
			# Comments in raw API data are structured as trees of comments containing other comments and various related objects. Our objective is to "de-link" these tree structures and subsequently identify comments entirely through direct ID reference.
			comment = rawData.data
			repliesListing = comment.replies?.data?.children
			if !Array.isArray(repliesListing) then repliesListing = []
			# Detect and process a "continue this thread" link in the comment's replies.
			if repliesListing.last?.kind is 'more' and repliesListing.last.depth >= 10
				repliesListing.pop()
				comment.deep_replies = true
			# Detect and process a "more comments" object in the comment's replies.
			if repliesListing.last?.kind is 'more'
				more = repliesListing.pop()
				comment.more_replies = more.data.children
			# Recursively extract all comments in this comment's reply tree.
			repliesListingDatasets = extract(comment.replies or []) # Sometimes Reddit sends an empty string instead of an empty array.
			# Set the IDs of the direct replies in place of the original objects.
			comment.replies = repliesListingDatasets.main.data
			result.main =
				id: rawData.data.id.asId('t1') # ...but when we recursively extract sub-objects, we need to identify them.
				data: comment
			result.sub = repliesListingDatasets.sub
		when 't2'
			result.main =
				id: rawData.data.name.toLowerCase().asId('t2i')
				data: rawData.data
		when 't3'
			post = rawData.data
			# Normalize the URL - sometimes it is only given as a relative path.
			post.url = if post.url[0] == '/' then new URL("https://www.reddit.com#{post.url}") else new URL(post.url)
			# Detect the content format for the post.
			post.format = switch
				when post.media?.reddit_video or post.is_gallery or post.post_hint == 'image' or post.url.hostname == 'i.redd.it'
					'media'
				when iFrames(post.url)
					'iframe'
				when post.poll_data
					'poll'
				when post.is_self
					'self'
				else
					'link'
			# Organize all the media we might need for the post.
			# For video or gif media, we also try to organize relevant static images.
			# Note that self posts sometimes also have media, as inline images.
			hosted_video_data = post.media?.reddit_video
			post.media = []
			if post.media_metadata and post.gallery_data and Array.isArray(post.gallery_data.items)
				post.media = post.gallery_data.items.map((item) ->
					mediaObject = { caption_text: item.caption, caption_url: item.outbound_url }
					data = post.media_metadata[item.media_id]
					if data.s.gif
						mediaObject.video_url = data.s.mp4 ? data.s.gif
						mediaObject.video_height = data.s.y
						mediaObject.video_width = data.s.x
					else
						mediaObject.image_url = data.s.u
						mediaObject['image_url_' + data.s.x] = data.s.u
					data.p.forEach((res) ->
						mediaObject['image_url_' + res.x] = res.u
					)
					return mediaObject
				)
			else if post.preview? and Array.isArray(post.preview.images)
				post.media = post.preview.images.map((item) ->
					mediaObject = {}
					if item.variants.gif 
						data = item.variants.mp4 ? item.variants.gif
						mediaObject.video_url = data.source.url
						mediaObject.video_height = data.source.height
						mediaObject.video_width = data.source.width
					mediaObject.image_url = item.source.url
					mediaObject['image_url_' + item.source.width] = item.source.url
					item.resolutions.forEach((res) ->
						mediaObject['image_url_' + res.width] = res.url
					)
					return mediaObject
				)
			else if post.url.hostname == 'i.redd.it'
				post.media[0] = if post.url.pathname.endsWith('gif') then { video_url: post.url } else { image_url: post.url }
			if hosted_video_data
				post.media[0] =
					video_url: video.fallback_url ? post.url
					video_height: video.height
					video_width: video.width
					video_audio_url: if video.fallback_url and !video.is_gif then video.fallback_url.replaceAll(/DASH_[0-9]+/g, 'DASH_audio') else null
			if iFrames(post.url)
				{ src, allow } = iFrames(post.url)
				post.media[0] =
					iframe_url: src
					iframe_allow: allow
			# Collect the post and (possible) subreddit objects.
			result.main =
				id: rawData.data.id.asId('t3')
				data: post
				partial: true # Marks objects known to be an incomplete version of data from another API route.
			if post.sr_detail
				result.sub.push({
					id: post.subreddit.toLowerCase().asId('t5i')
					data: post.sr_detail
					partial: true
				})
				delete post.sr_detail
		when 't4'
			result.main =
				id: rawData.data.id.asId('t4')
				data: rawData.data
		when 't5'
			result.main =
				id: rawData.data.display_name.toLowerCase().asId('t5i')
				data: rawData.data
		when 't6'
			result.main =
				id: rawData.data.id.asId('t6')
				data: rawData.data
		else
			result.main =
				id: null
				data: rawData
	return result

iFrames = (url) -> switch (if url.hostname.startsWith('www') then url.hostname[4..] else url.hostname)
	when 'clips.twitch.tv'
		descriptor = url.pathname.split('/')[1]
		if descriptor?.length
			src: "https://clips.twitch.tv/embed?clip=#{descriptor}&parent=#{location.hostname}"
		else
			null
	when 'gfycat.com'
		descriptor = url.pathname.split('/')[1]
		if descriptor?.length
			src: "https://gfycat.com/ifr/#{descriptor}"
		else
			null
	when 'm.twitch.tv'
		descriptor = url.pathname.split('/')[2]
		if descriptor?.length
			src: "https://clips.twitch.tv/embed?clip=#{descriptor}&parent=#{location.hostname}"
		else
			null
	when 'redgifs.com'
		descriptor = url.pathname.split('/')[2]
		if descriptor?.length
			src: "https://redgifs.com/ifr/#{descriptor}"
		else
			null
	when 'twitch.tv'
		descriptor = url.pathname.split('/')[3]
		if descriptor?.length
			src: "https://clips.twitch.tv/embed?clip=#{descriptor}&parent=#{location.hostname}"
		else
			null
	when 'youtu.be'
		descriptor = url.pathname.split('/')[1]
		if descriptor?.length
			src: "https://www.youtube.com/embed/#{descriptor}"
			allow: 'accelerometer; clipboard-write; encrypted-media; gyroscope; picture-in-picture'
		else
			null
	when 'youtube.com'
		descriptor = url.searchParams.get('v')
		if descriptor?.length and url.pathname.split('/')[1] != 'clip' # clip URLs don't contain the information necessary for embedding
			src: "https://www.youtube.com/embed/#{descriptor}",
			allow: 'accelerometer; clipboard-write; encrypted-media; gyroscope; picture-in-picture'
		else
			null
	else
		null