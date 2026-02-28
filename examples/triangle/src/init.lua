local vk = require("vkapi")
local winit = require("winit")
local ffi = require("ffi")

local instance = vk.createInstance({
	enabledExtensionNames = { "VK_KHR_surface", "VK_KHR_xlib_surface" },
	enabledLayerNames = { "VK_LAYER_KHRONOS_validation" },
	applicationInfo = {
		name = "triangle test",
		version = 1.0,
		engineName = "vkapi",
		engineVersion = 1.0,
		apiVersion = vk.ApiVersion.V1_0,
	}
})

local devices = instance:enumeratePhysicalDevices()
local physicalDevice = devices[1] -- Fallback to first

-- Prefer dgpu
for _, pd in ipairs(devices) do
	local props = vk.getPhysicalDeviceProperties(pd)
	if props.deviceType == vk.PhysicalDeviceType.DISCRETE_GPU then
		physicalDevice = pd
	end
end

---@type number?
local queueFamilyIdx

for idx, family in ipairs(vk.getPhysicalDeviceQueueFamilyProperties(physicalDevice)) do
	if bit.band(family.queueFlags, vk.QueueFlagBits.GRAPHICS) ~= 0 then
		queueFamilyIdx = idx - 1
		break
	end
end

if not queueFamilyIdx then
	error("No graphics queue family found")
end

local device = instance:createDevice(physicalDevice, {
	enabledExtensionNames = { "VK_KHR_swapchain" },
	queueCreateInfos = {
		{
			queueFamilyIndex = queueFamilyIdx,
			queuePriorities = { 1.0 },
			queueCount = 1,
		},
	},
})

local eventLoop = winit.EventLoop.new()
local window = winit.Window.new(eventLoop, 800, 600)
eventLoop:register(window)

---@type vk.ffi.SurfaceKHR
local surface

if ffi.os == "Linux" then ---@cast window winit.x11.Window
	surface = instance:createXlibSurfaceKHR({
		dpy = window.display,
		window = window.id,
	})
elseif ffi.os == "Windows" then ---@cast window winit.win32.Window
	surface = instance:createWin32SurfaceKHR({
		hinstance = window.id,
		hwnd = window.hwnd,
	})
else
	error("Unsupported platform: " .. ffi.os)
end

local queue = device:getDeviceQueue(queueFamilyIdx, 0)

local commandPool = device:createCommandPool({
	queueFamilyIndex = queueFamilyIdx,
})

local renderPass = device:createRenderPass({
	attachments = {
		{
			format = vk.Format.B8G8R8A8_UNORM,
			samples = vk.SampleCountFlagBits.COUNT_1,
			loadOp = vk.AttachmentLoadOp.CLEAR,
			storeOp = vk.AttachmentStoreOp.STORE,
			stencilLoadOp = vk.AttachmentLoadOp.DONT_CARE,
			initialLayout = vk.ImageLayout.UNDEFINED,
			finalLayout = vk.ImageLayout.PRESENT_SRC_KHR,
		}
	},
	subpasses = {
		{
			pipelineBindPoint = vk.PipelineBindPoint.GRAPHICS,
			colorAttachments = {
				{
					layout = vk.ImageLayout.GENERAL,
					attachment = 0
				}
			}
		}
	}
})

local swapchain = device:createSwapchainKHR({
	surface = surface,
	minImageCount = 2,
	imageFormat = vk.Format.B8G8R8A8_UNORM,
	imageColorSpace = vk.ColorSpaceKHR.SRGB_NONLINEAR,
	imageExtent = { width = window.width, height = window.height },
	imageArrayLayers = 1,
	imageUsage = vk.ImageUsageFlagBits.COLOR_ATTACHMENT,
	imageSharingMode = vk.SharingMode.EXCLUSIVE,
	preTransform = vk.SurfaceTransformFlagBitsKHR.IDENTITY,
	compositeAlpha = vk.CompositeAlphaFlagBitsKHR.OPAQUE,
	presentMode = vk.PresentModeKHR.FIFO,
	clipped = 1,
	oldSwapchain = nil,
})

local swapchainImages = device:getSwapchainImagesKHR(swapchain)

local imageViews = {}
local framebuffers = {}

for i, image in ipairs(swapchainImages) do
	local imageView = device:createImageView({
		image = image,
		viewType = vk.ImageViewType.TYPE_2D,
		format = vk.Format.B8G8R8A8_UNORM,
		subresourceRange = {
			aspectMask = vk.ImageAspectFlagBits.COLOR,
			baseMipLevel = 0,
			levelCount = 1,
			baseArrayLayer = 0,
			layerCount = 1,
		},
		components = {
			r = vk.ComponentSwizzle.IDENTITY,
			g = vk.ComponentSwizzle.IDENTITY,
			b = vk.ComponentSwizzle.IDENTITY,
			a = vk.ComponentSwizzle.IDENTITY,
		}
	})

	imageViews[i] = imageView

	local attachments = vk.ImageViewArray(1)
	attachments[0] = imageView

	local framebuffer = device:createFramebuffer({
		renderPass = renderPass,
		width = window.width,
		height = window.height,
		layers = 1,
		attachmentCount = 1,
		pAttachments = attachments
	})

	framebuffers[i] = framebuffer
end

local commandBuffer = device:allocateCommandBuffers({
	commandPool = commandPool,
	level = vk.CommandBufferLevel.PRIMARY,
	commandBufferCount = 1,
})[1]

local pipelineLayout = device:createPipelineLayout({})

local vertexModule ---@type vk.ffi.ShaderModule
do
	local code = io.open("shaders/triangle.vert.spv", "rb"):read("*a")
	vertexModule = device:createShaderModule({
		codeSize = #code,
		pCode = ffi.cast("const uint32_t*", code),
	})
end

local fragmentModule ---@type vk.ffi.ShaderModule
do
	local code = io.open("shaders/triangle.frag.spv", "rb"):read("*a")
	fragmentModule = device:createShaderModule({
		codeSize = #code,
		pCode = ffi.cast("const uint32_t*", code),
	})
end

local vertexBuffer = device:createBuffer({
	size = 3 * ffi.sizeof("float") * 7, -- 3 vertices, each with 3 floats for position and 4 for color
	usage = vk.BufferUsageFlagBits.VERTEX_BUFFER,
})

do
	local memoryRequirements = device:getBufferMemoryRequirements(vertexBuffer)

	local memoryTypeIndex = nil ---@type number?
	local properties = vk.getPhysicalDeviceMemoryProperties(physicalDevice)
	for i = 0, properties.memoryTypeCount - 1 do
		local memType = properties.memoryTypes[i] ---@type vk.ffi.MemoryType
		if bit.band(memoryRequirements.memoryTypeBits, bit.lshift(1, i)) ~= 0 and
			bit.band(memType.propertyFlags, vk.MemoryPropertyFlagBits.HOST_VISIBLE) ~= 0 and
			bit.band(memType.propertyFlags, vk.MemoryPropertyFlagBits.HOST_COHERENT) ~= 0
		then
			memoryTypeIndex = i
			break
		end
	end

	local memoryChunk = device:allocateMemory({
		allocationSize = memoryRequirements.size,
		memoryTypeIndex = assert(memoryTypeIndex, "No suitable memory type found for vertex buffer")
	})

	device:bindBufferMemory(vertexBuffer, memoryChunk, 0)
end

local indexBuffer = device:createBuffer({
	size = 3 * ffi.sizeof("uint16_t"),
	usage = vk.BufferUsageFlagBits.INDEX_BUFFER,
})


do
	local memoryRequirements = device:getBufferMemoryRequirements(indexBuffer)

	local memoryTypeIndex = nil ---@type number?
	local properties = vk.getPhysicalDeviceMemoryProperties(physicalDevice)
	for i = 0, properties.memoryTypeCount - 1 do
		local memType = properties.memoryTypes[i] ---@type vk.ffi.MemoryType
		if bit.band(memoryRequirements.memoryTypeBits, bit.lshift(1, i)) ~= 0 and
			bit.band(memType.propertyFlags, vk.MemoryPropertyFlagBits.HOST_VISIBLE) ~= 0 and
			bit.band(memType.propertyFlags, vk.MemoryPropertyFlagBits.HOST_COHERENT) ~= 0
		then
			memoryTypeIndex = i
			break
		end
	end

	local memoryChunk = device:allocateMemory({
		allocationSize = memoryRequirements.size,
		memoryTypeIndex = assert(memoryTypeIndex, "No suitable memory type found for index buffer")
	})

	device:bindBufferMemory(indexBuffer, memoryChunk, 0)
end

local pipeline = device:createGraphicsPipelines(nil, { {
	renderPass = renderPass,

	rasterizationState = {
		polygonMode = vk.PolygonMode.FILL,
		cullMode = vk.CullModeFlagBits.BACK,
		frontFace = vk.FrontFace.CLOCKWISE,
		lineWidth = 1.0,
	},

	multisampleState = {
		rasterizationSamples = vk.SampleCountFlagBits.COUNT_1,
	},

	vertexInputState = {
		attributes = {
			{
				location = 0,
				binding = 0,
				format = vk.Format.R32G32B32_SFLOAT,
				offset = 0,
			},
			{
				location = 1,
				binding = 0,
				format = vk.Format.R32G32B32A32_SFLOAT,
				offset = 12,
			}
		},
		bindings = {
			{
				binding = 0,
				stride = 28,
				inputRate = vk.VertexInputRate.VERTEX,
			}
		}
	},

	inputAssemblyState = {
		topology = vk.PrimitiveTopology.TRIANGLE_LIST,
		primitiveRestartEnable = false,
	},

	colorBlendState = {
		attachments = {
			{
				colorWriteMask = bit.bor(
					vk.ColorComponentFlagBits.R,
					vk.ColorComponentFlagBits.G,
					vk.ColorComponentFlagBits.B,
					vk.ColorComponentFlagBits.A
				),
				blendEnable = false,
			}
		}
	},

	viewportState = {
		viewportCount = 1,
		scissorCount = 1,
	},

	dynamicState = {
		dynamicStates = {
			vk.DynamicState.VIEWPORT,
			vk.DynamicState.SCISSOR,
		}
	},

	stages = {
		{
			stage = vk.ShaderStageFlagBits.VERTEX_BIT,
			module = vertexModule
		},
		{
			stage = vk.ShaderStageFlagBits.FRAGMENT_BIT,
			module = fragmentModule
		}
	},
	layout = pipelineLayout
} })[1]

local scissors = vk.Rect2DArray(1)
scissors[0] = {
	offset = { x = 0, y = 0 },
	extent = { width = 800, height = 600 },
}

local viewports = vk.ViewportArray(1)
viewports[0] = {
	x = 0,
	y = 0,
	width = 800,
	height = 600,
	minDepth = 0.0,
	maxDepth = 1.0,
}

local renderPassBeginInfo = vk.RenderPassBeginInfo()
renderPassBeginInfo.renderPass = renderPass
renderPassBeginInfo.framebuffer = framebuffers[1]
renderPassBeginInfo.renderArea = {
	offset = { x = 0, y = 0 },
	extent = { width = 800, height = 600 },
}
renderPassBeginInfo.clearValueCount = 1
renderPassBeginInfo.pClearValues = vk.ClearValueArray(1)
renderPassBeginInfo.pClearValues[0].color.float32[0] = 1.0
renderPassBeginInfo.pClearValues[0].color.float32[1] = 0.0
renderPassBeginInfo.pClearValues[0].color.float32[2] = 0.0
renderPassBeginInfo.pClearValues[0].color.float32[3] = 1.0

local imageAvailableSemaphore = device:createSemaphore({})
local renderFinishedSemaphore = device:createSemaphore({})
local inFlightFence = device:createFence({ flags = vk.FenceCreateFlagBits.SIGNALED })

local swapchains = vk.SwapchainKHRArray(1)
swapchains[0] = swapchain

local imageIndices = ffi.new("uint32_t[1]")

local waitSemaphores = vk.SemaphoreArray(1)
waitSemaphores[0] = imageAvailableSemaphore

local signalSemaphores = vk.SemaphoreArray(1)
signalSemaphores[0] = renderFinishedSemaphore

local queueSubmits = vk.SubmitInfoArray(1)
do
	local commandBuffers = vk.CommandBufferArray(1)
	commandBuffers[0] = commandBuffer

	queueSubmits[0] = vk.SubmitInfo({
		waitSemaphoreCount = 1,
		pWaitSemaphores = waitSemaphores,
		pWaitDstStageMask = ffi.new("uint32_t[2]", vk.PipelineStageFlagBits.COLOR_ATTACHMENT_OUTPUT, 0),
		commandBufferCount = 1,
		pCommandBuffers = commandBuffers,
		signalSemaphoreCount = 1,
		pSignalSemaphores = signalSemaphores,
	})
end

local vertexBuffers = vk.BufferArray(1)
vertexBuffers[0] = vertexBuffer

local vertexBufferOffsets = vk.DeviceSizeArray(1)
vertexBufferOffsets[0] = 0

local function draw()
	-- Reuse previous command buffer for simplicity, but you'd want to double/triple buffer usually
	device:resetCommandPool(commandPool)

	device:waitForFences({ inFlightFence }, true, math.huge)
	device:resetFences({ inFlightFence })

	local imageIndex = device:acquireNextImageKHR(swapchain, -1, imageAvailableSemaphore, nil)
	renderPassBeginInfo.framebuffer = framebuffers[imageIndex + 1]
	imageIndices[0] = imageIndex

	device:beginCommandBuffer(commandBuffer)
	device:cmdSetScissor(commandBuffer, 0, 1, scissors)
	device:cmdSetViewport(commandBuffer, 0, 1, viewports)
	device:cmdBeginRenderPass(commandBuffer, renderPassBeginInfo, vk.SubpassContents.INLINE)
	device:cmdBindVertexBuffers(commandBuffer, 0, 1, vertexBuffers, vertexBufferOffsets)
	device:cmdBindIndexBuffer(commandBuffer, indexBuffer, 0, vk.IndexType.UINT16)
	device:cmdBindPipeline(commandBuffer, vk.PipelineBindPoint.GRAPHICS, pipeline)
	device:cmdDraw(commandBuffer, 3, 1, 0, 0)
	device:cmdEndRenderPass(commandBuffer)
	device:endCommandBuffer(commandBuffer)

	device:queueSubmit(queue, 1, queueSubmits, inFlightFence)
	device:queuePresentKHR(queue, swapchain, imageIndex, renderFinishedSemaphore)
end

eventLoop:run(function(event, handler)
	if event.name == "redraw" then
		draw()
	elseif event.name == "windowClose" then
		handler:exit()
	end
end)
