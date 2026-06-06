import Foundation

/// Ready-to-paste sample definitions (XState JSON) for the paste app's editor.
enum SampleMachines {
    /// A traffic light with a nested `red` (wait → walk) compound state.
    static let trafficLight = """
    {
      "id": "trafficLight",
      "initial": "green",
      "context": { "ticks": 0 },
      "states": {
        "green": { "on": { "NEXT": "yellow" } },
        "yellow": { "on": { "NEXT": "red" } },
        "red": {
          "initial": "wait",
          "states": {
            "wait": { "on": { "COUNTDOWN": "walk" } },
            "walk": { "on": { "COUNTDOWN_END": "stop" } },
            "stop": { "type": "final" }
          },
          "on": { "NEXT": "green" }
        }
      }
    }
    """

    /// A parallel machine: two independent regions active at once.
    static let editor = """
    {
      "id": "editor",
      "type": "parallel",
      "states": {
        "bold": {
          "initial": "off",
          "states": {
            "off": { "on": { "TOGGLE_BOLD": "on" } },
            "on": { "on": { "TOGGLE_BOLD": "off" } }
          }
        },
        "italic": {
          "initial": "off",
          "states": {
            "off": { "on": { "TOGGLE_ITALIC": "on" } },
            "on": { "on": { "TOGGLE_ITALIC": "off" } }
          }
        }
      }
    }
    """
}
