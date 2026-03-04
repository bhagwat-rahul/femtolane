# GUI for femtolane

This folder contains all the gui/rendering/drawing code for femtolane.

The GUI is a central piece of the program, and while it can be run as a CLI, we want to provide the same amount of power via the GUI as well
with a better user experience.

Some things we need the GUI to implement:-

1. A frontend to the tool for providing options to manage the 'flow' as an alternative to tcl/python scripting
2. Visualising net hypergraphs
3. Visualising oasis files

## GUI notes

1. All options present in the GUI should also be present in the scripting layer (and vice-versa)
2. Ideally should be cross-platform (windows, posix, wasm) and no dependency, except raylib (and it's deps)
3. Performant:- Consistently run at 120 fps
4. Possibly have some kind of free-form window tiling/docking system within it that's super intuitive and easy to use
5. Trying to make the interface look and feel somewhat like a debugger interface
6. We ideally want to build our own UI using nothing but `vendor:raylib` from Odin.
7. Will have to implement docking, managing ui state, etc. on top of raygui for the UI itself.
8. Over time, if needed even remove raylib and go fully custom, although it's good to have for now to speedup dev until we get to MVP/alpha.
