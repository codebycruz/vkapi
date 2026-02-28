# triangle

This example renders a triangle using vkapi.

It uses [winit](https://github.com/codebycruz/winit) for window handling, but otherwise no other dependencies.

It also shows best practices for minimizing allocations (putting them outside of the rendering loop, and writing memory in place with LuaJIT)
