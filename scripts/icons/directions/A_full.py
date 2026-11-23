"""Direction A for every ribbon icon the app uses (the names of gen.py ICONS and apple/Resources/ToolIcons).

The 8 review commands keep the subjects of the picked candidates (common.SUBJECTS plus A's retakes); the other 24 are
the gen.py subjects rewritten with BODY (a neutral grey part) and ACCENT (the acted-on part in blue).
"""
from . import common, A

SUBJECTS = dict(common.SUBJECTS)
SUBJECTS.update(A.OVERRIDES)
SUBJECTS["joint"] = common.RETAKES["joint"]  # the first full-set pass was too busy at 26 px
SUBJECTS.update({
    # Create
    "box": "A single cube with crisp edges; its top face is ACCENT, the sides are BODY.",
    "cylinder": "A single upright cylinder; its top circular face is ACCENT, the side is BODY.",
    # Modify
    "presspull": "A rectangular block that is BODY; its top face is ACCENT and raised a little, with one thick ACCENT "
                 "double-headed arrow pointing up and down above it.",
    "chamfer": "A rectangular block that is BODY; one long top front edge is cut off at 45 degrees and that flat bevel "
               "face is ACCENT.",
    "shell": "An open box hollowed out with thick walls, seen from above; the outer walls are BODY and the inner floor "
             "and inner walls are ACCENT.",
    "combine": "A cube that is BODY and a sphere that is ACCENT interpenetrating, merged into one solid.",
    "delete": "A cube that is BODY with one bold ACCENT X made of two thick crossed rounded bars in front of its lower "
              "right corner.",
    # Assemble
    "component": "Two flat blocks stacked and exploded slightly apart vertically; the lower block is BODY, the upper "
                 "block is ACCENT.",
    "as_built": "Two thick plates that are BODY, overlapping at one corner and already touching, held by one round ACCENT "
                "pin through both. No arrow.",
    "rigid_group": "Three cubes that are BODY locked together in an L shape, wrapped by one thick ACCENT rounded band "
                   "around all three.",
    "capture": "A cube that is BODY framed by four thick ACCENT corner brackets, like a camera viewfinder around it.",
    # Configure, construct
    "configuration_table": "A thick rounded square tile that is BODY carrying a 3 by 3 grid of raised square cells; the "
                           "top row of cells is ACCENT.",
    "plane": "A small cube that is BODY with one large thin flat square ACCENT plate floating horizontally above it.",
    "plane_angle": "A small cube that is BODY with one large thin flat square ACCENT plate passing through its top edge, "
                   "tilted at 30 degrees.",
    "axis_through_cylinder": "An upright cylinder that is BODY with one long thick ACCENT rod passing vertically through "
                             "its centre, sticking out well above and below.",
    "point_vertex": "A cube that is BODY; its top front corner holds one bold round ACCENT dot, clearly larger than the "
                    "edge thickness.",
    # Inspect
    "interference": "Two large cubes that are BODY, side by side and overlapping by about a third; the overlapping "
                    "volume where they intersect is one solid ACCENT block. No arrows, nothing else.",
    # Insert
    "import": "An open box that is BODY seen from above, with one short thick ACCENT arrow pointing down into it.",
    "fastener": "A single upright hex bolt: the hexagonal head is BODY, the threaded shank is ACCENT.",
    "library": "Three thick books standing upright side by side; the outer two are BODY, the middle one is ACCENT.",
    # Electronics
    "board": "A thick rounded rectangular printed circuit board that is BODY, seen in isometric view, with one square "
             "ACCENT chip in its centre and three chunky raised ACCENT traces running from the chip to the edges.",
    "cube3d": "A cube that is BODY with a thin ACCENT circuit board plate lying flat on its top face.",
    "mount": "A thin circuit board that is ACCENT hovering above a block that is BODY, with one short thick ACCENT arrow "
             "pointing down between them.",
    # Shell
    "select": "A single bold mouse pointer arrow tilted to the upper left, slightly thick like a flat 3D token: its top "
              "face is BODY, its tip is ACCENT.",
})
