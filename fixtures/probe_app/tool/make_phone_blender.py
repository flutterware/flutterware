# The store listing's phone, built in Blender and exported as glTF.
#
# `make_probe_rig_blender.py` builds a *probe* — a box with a lid, whose job is
# to answer questions about the pipeline. This builds the thing a listing
# actually shows: a phone with rounded corners, a camera bump and a screen a
# scene binds a screenshot to. Run headless, from `fixtures/probe_app`:
#
#     /Applications/Blender.app/Contents/MacOS/Blender --background \
#         --python tool/make_phone_blender.py
#
# It follows the surface convention the walk tests hold:
#
#   * the object's name is the glTF node's name, so `mesh: 'Screen'` finds it;
#   * a plane facing -Y in Blender faces the viewer after export;
#   * the exporter flips V, so Blender's default plane UVs land top-left —
#     which is the only reason a bound screenshot is not upside down;
#   * everything is centred on the origin, so the orbit camera's target is the
#     phone rather than a corner of it.
#
# There is deliberately no animation here. The probe rig carries a clip because
# clips had to be proven; a phone in a store banner turns because the scene's
# timeline keys `rotationY` on its placement, and a row on the timeline is the
# thing worth showing.
#
# No screen aspect is invented: 0.68 x 1.473 is 19.5:9, which is what every
# phone the listing targets is.
import os

import bpy

bpy.ops.wm.read_factory_settings(use_empty=True)

SCREEN_WIDTH = 0.68
SCREEN_HEIGHT = 1.473
BODY_WIDTH = 0.75
BODY_HEIGHT = 1.55
BODY_DEPTH = 0.085


def material(name, rgba, roughness=0.5, metallic=0.0):
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes["Principled BSDF"]
    bsdf.inputs["Base Color"].default_value = rgba
    bsdf.inputs["Roughness"].default_value = roughness
    bsdf.inputs["Metallic"].default_value = metallic
    return mat


def box(name, size, location, mat):
    bpy.ops.mesh.primitive_cube_add(size=1, location=location)
    obj = bpy.context.active_object
    obj.name = name
    obj.data.name = name
    obj.scale = size
    bpy.ops.object.transform_apply(scale=True)
    obj.data.materials.append(mat)
    return obj


def bevel(obj, width, segments):
    """Rounds an object's edges in place.

    A phone's corners are the one piece of its silhouette a viewer reads at
    banner size; a box with square corners reads as a slab no matter what
    material it wears.
    """
    modifier = obj.modifiers.new("Bevel", "BEVEL")
    modifier.width = width
    modifier.segments = segments
    modifier.limit_method = "ANGLE"
    bpy.context.view_layer.objects.active = obj
    bpy.ops.object.modifier_apply(modifier="Bevel")
    # Blender 5 dropped the mesh-level auto-smooth flag; the operator that
    # replaced it carries the angle itself, and a bevel with six segments needs
    # it or every segment reads as a facet.
    bpy.ops.object.shade_auto_smooth(angle=0.5236)


body = box(
    "Body",
    (BODY_WIDTH, BODY_DEPTH, BODY_HEIGHT),
    (0, 0, 0),
    material("BodyMat", (0.045, 0.048, 0.055, 1), 0.35, 0.9),
)
bevel(body, 0.05, 6)

# The screen: Blender's default plane faces +Z, so it is turned to face -Y and
# sits a hair in front of the body's front face. `export_apply` bakes the
# rotation, and the default UVs come through untouched — which is what the
# renderer binds the screenshot to.
bpy.ops.mesh.primitive_plane_add(size=1, location=(0, -(BODY_DEPTH / 2) - 0.001, 0))
screen = bpy.context.active_object
screen.name = "Screen"
screen.data.name = "Screen"
screen.rotation_euler = (1.5707963267948966, 0, 0)
screen.scale = (SCREEN_WIDTH, SCREEN_HEIGHT, 1)
bpy.ops.object.transform_apply(rotation=True, scale=True)
# White and fully rough: the bound texture is multiplied by this base colour,
# so anything but white tints the app's own pixels.
screen.data.materials.append(material("ScreenMat", (1, 1, 1, 1), 1.0, 0.0))

# The camera bump, on the back. Two lenses, because one reads as a sensor and
# three reads as a specific phone nobody licensed us to draw.
bump = box(
    "CameraBump",
    (0.22, 0.02, 0.24),
    (-0.22, (BODY_DEPTH / 2) + 0.01, 0.58),
    material("BumpMat", (0.03, 0.03, 0.035, 1), 0.3, 0.9),
)
bevel(bump, 0.03, 4)
for index, z in enumerate((0.64, 0.52)):
    lens = box(
        f"Lens{index + 1}",
        (0.09, 0.012, 0.09),
        (-0.22, (BODY_DEPTH / 2) + 0.026, z),
        material(f"LensMat{index + 1}", (0.01, 0.012, 0.02, 1), 0.05, 0.2),
    )
    bevel(lens, 0.02, 4)

# Side buttons, on the right edge as the viewer sees it.
box(
    "Power",
    (0.012, 0.03, 0.18),
    ((BODY_WIDTH / 2) + 0.002, 0, 0.35),
    material("ButtonMat", (0.12, 0.13, 0.15, 1), 0.3, 0.9),
)
box(
    "Volume",
    (0.012, 0.03, 0.26),
    (-(BODY_WIDTH / 2) - 0.002, 0, 0.4),
    bpy.data.materials["ButtonMat"],
)

out = os.path.join(os.getcwd(), "assets", "models", "phone.glb")
os.makedirs(os.path.dirname(out), exist_ok=True)
bpy.ops.export_scene.gltf(
    filepath=out,
    export_format="GLB",
    export_apply=True,
    export_animations=False,
    export_yup=True,
)
print("wrote", out, os.path.getsize(out), "bytes")
