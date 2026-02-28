local vk = require("vkapi")
local winit = require("winit")

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

eventLoop:run(function(event)
	if event.name == "redraw" then
		print("redraw")
	end
end)
