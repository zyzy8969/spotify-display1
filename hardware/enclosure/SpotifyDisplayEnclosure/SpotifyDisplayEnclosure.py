"""Spotify Display enclosure, V1 ("black box").

Fusion 360 script. It builds a parametric enclosure for the Waveshare ESP32-S3-LCD-1.3
board plus a small LiPo, then exports print-ready STLs to ./stl next to this file.

Run it in Fusion: UTILITIES > ADD-INS > Scripts and Add-Ins > "+" > Script or add-in from
device > choose this folder > Run. Each run opens one new design per entry in VARIANTS
(top keyring loop, corner keyring loop, belt clip). To change the box, edit the
PARAMETERS block below and run the script again.

Axes (mm):  X = screen width, right is +.  Y = screen height, top is + (the LCD's black
FPC strip is at the bottom, -Y).  Z = depth: the front face of the brim is z = 0 and +Z
points toward the back of the box.  The shell is modelled in print orientation (front
face on the bed).  Flip the lid before printing (outside face on the bed).

Parts:
  Shell      - front brim (covers the screen border and the black FPC strip) + walls.
               USB-C cut-out on the bottom edge, power-switch slot on the top edge, vent
               slots in both side walls, two screw bosses.
  Lid        - back cover with vent slots, four posts that press the board's brass
               standoffs so the glass sits against the brim, two M2 screw holes.
  Reference  - board, standoffs, USB-C and battery mock-ups for checking fit. Not exported.

Sources for the board numbers: the LCD panel datasheet (26.16 x 29.22 mm module, 23.4 mm
square active area, starting 1.33 mm from the top edge), Waveshare's board drawing
(26.25 x 29.22 PCB, M2 holes 22.55 x 25.44, 11.40 mm from glass to standoff ends) and the
schematic (standoffs "M2 3.5*5": 3.5 mm hex, 5 mm long).  Values marked ESTIMATE were read
off a photo and must be checked against the real board.
"""

import math
import os
import traceback

import adsk.core
import adsk.fusion

# ============================== PARAMETERS (mm) ==============================

# --- Board: Waveshare ESP32-S3-LCD-1.3 ---
PCB_W = 26.25               # PCB width (X). LCD module is 26.16 wide.
PCB_H = 29.22               # PCB height (Y). LCD module is 29.22 tall.
AA = 23.40                  # LCD active area (square)
AA_DY = 1.58                # active-area centre sits this far ABOVE the PCB centre
MODULE_DEPTH = 11.40        # LCD glass front -> end of the brass standoffs
STANDOFF_DX = 22.55         # standoff spacing, X
STANDOFF_DY = 25.44         # standoff spacing, Y
STANDOFF_HEX = 3.5          # standoff across-flats (reference model only)
PCB_BACK_FROM_GLASS = 6.4   # ESTIMATE: glass front -> back face of the PCB

# --- Battery: default 502025 LiPo (5 x 20 x 25), laid with its 25 mm side along X ---
BAT_X = 25.0
BAT_Y = 20.0
BAT_T = 5.0
BAT_CLEAR = 1.0             # extra depth for wires, foam pad, and normal LiPo swelling

# --- Shell ---
FIT = 0.30                  # gap around the PCB, each side
WALL = 1.6                  # side walls (4 perimeters with a 0.4 nozzle)
BEZEL = 1.2                 # thickness of the front brim over the glass
CORNER_R = 2.0              # outside corner radius
WINDOW_INSET = 0.10         # window is this much smaller than the active area, per side
WINDOW_R = 0.6              # window corner radius
FRONT_CHAMFER = 0.6         # chamfer on the front outside edge
WINDOW_CHAMFER = 0.5        # chamfer on the window edge

# --- Lid and fasteners ---
LID_T = 2.0
LID_FILLET = 0.6
HEAT_INSERTS = False        # False: M2 self-tapping screws.  True: M2 heat-set inserts (3.2 OD).
BOSS_X = 7.0                # bosses at (-BOSS_X, top wall) and (+BOSS_X, bottom wall)
SCREW_CLEAR_D = 2.3
CBORE_D = 4.2               # counterbore for an M2 pan head
CBORE_DEPTH = 1.2
POST_D = 3.0                # lid posts that press the standoff ends
POST_PRELOAD = 0.10         # posts reach this far past the nominal standoff ends

# --- USB-C cut-out (bottom edge) ---
USB_X = 0.0                 # ESTIMATE: centred on the bottom edge
USB_Z_FROM_GLASS = 8.0      # ESTIMATE: glass front -> centre of the port (PCB back + 1.6)
USB_W = 9.8
USB_H = 4.2
USB_RECESS_W = 12.5         # shallow outside pocket so moulded plugs seat fully
USB_RECESS_H = 7.0
USB_RECESS_DEPTH = 0.6

# --- Power switch slot (top edge, behind the board, centred on the battery bay) ---
SW_X = 5.5
SW_W = 5.0                  # along X: lever width + travel + slack (SS-12D00G3)
SW_H = 2.6                  # along Z

# --- Vents ---
SIDE_VENT_COUNT = 7
SIDE_VENT_PITCH = 3.0
SIDE_VENT_W = 1.2
SIDE_VENT_LEN = 6.0
SIDE_VENT_ZC_FROM_GLASS = 6.3
LID_VENT_COUNT = 5
LID_VENT_PITCH = 3.0
LID_VENT_W = 1.4
LID_VENT_LEN = 12.0

# --- Mount variants: each one is built in its own design and exported as its own STLs ---
#   top_loop    - keyring loop centred on the top edge, so the keychain hangs straight
#   corner_loop - keyring loop on the top-left corner (hangs as a diamond)
#   belt_clip   - no loop; spring clip on the lid that slides over a belt or belt loop
VARIANTS = ("top_loop", "corner_loop", "belt_clip")

# Keyring loop (part of the shell, centred in the box's depth so it hangs straight)
LUG_R = 4.0                 # outer radius of the loop
LUG_HOLE_D = 3.5            # fits split rings and lanyard cord
LUG_OFFSET = 4.0            # hole centre beyond the outside edge
LUG_T = 5.0                 # thickness of the loop (along Z)

# Belt clip (part of the lid)
CLIP_W = 9.0                # narrow enough to clear the lid's top screw
CLIP_T = 1.8                # tongue thickness (spring)
CLIP_GAP = 1.2              # gap between lid and tongue; the tongue flexes open for the belt
CLIP_ROOT = 5.0             # length of the solid root block at the top
CLIP_EDGE = 1.0             # root block inset from the top edge
CLIP_TIP_MARGIN = 2.0       # tongue tip inset from the bottom edge
CLIP_LEAD = 3.0             # lead-in ramp at the tongue tip: length along Y...
CLIP_LEAD_DEPTH = 0.9       # ...and depth into the tongue

BUILD_REFERENCE = True
EXPORT_STL = True

# ============================================================================

MM = 0.1  # the Fusion API works in centimetres

NEW = adsk.fusion.FeatureOperations.NewBodyFeatureOperation
JOIN = adsk.fusion.FeatureOperations.JoinFeatureOperation
CUT = adsk.fusion.FeatureOperations.CutFeatureOperation


class Dims:
    """Derived sizes."""

    def __init__(self):
        self.cav_w = PCB_W + 2 * FIT
        self.cav_h = PCB_H + 2 * FIT
        self.out_w = self.cav_w + 2 * WALL
        self.out_h = self.cav_h + 2 * WALL
        self.z_so = BEZEL + MODULE_DEPTH            # plane of the standoff ends
        self.shell_d = self.z_so + BAT_T + BAT_CLEAR
        self.z_back = self.shell_d + LID_T
        self.boss_r = 2.7 if HEAT_INSERTS else 2.2
        self.boss_inset = 1.2 if HEAT_INSERTS else 0.7  # boss centre, inward of the wall
        self.boss_y = self.cav_h / 2 - self.boss_inset
        self.hole_d = 3.2 if HEAT_INSERTS else 1.7
        self.hole_depth = 4.0 if HEAT_INSERTS else (self.shell_d - self.z_so)
        self.bosses = ((-BOSS_X, self.boss_y), (BOSS_X, -self.boss_y))
        sx, sy = STANDOFF_DX / 2, STANDOFF_DY / 2
        self.standoffs = ((-sx, -sy), (sx, -sy), (sx, sy), (-sx, sy))

    def warnings(self):
        w = []
        bat_half_y = BAT_Y / 2 + 0.5
        if BAT_X + 0.6 > self.cav_w:
            w.append("Battery is too wide for the cavity (X).")
        if bat_half_y > STANDOFF_DY / 2 - POST_D / 2:
            w.append("Battery hits the lid posts (Y). Max battery Y is %.1f mm."
                     % (2 * (STANDOFF_DY / 2 - POST_D / 2) - 1.0))
        if bat_half_y > self.boss_y - self.boss_r:
            w.append("Battery hits the screw bosses (Y).")
        d = math.hypot(STANDOFF_DX / 2 - BOSS_X, self.boss_y - STANDOFF_DY / 2)
        if d < POST_D / 2 + self.boss_r + 0.2:
            w.append("Lid posts hit the screw bosses. Move BOSS_X toward 0.")
        if abs(SW_X + BOSS_X) < SW_W / 2 + self.boss_r + 0.5:
            w.append("Switch slot overlaps the top screw boss.")
        if "belt_clip" in VARIANTS and CLIP_W / 2 + CBORE_D / 2 + 0.3 > BOSS_X:
            w.append("Belt clip covers the lid screws. Make CLIP_W smaller.")
        if "top_loop" in VARIANTS and LUG_R + 0.5 > abs(SW_X) - SW_W / 2 \
                and abs(BEZEL + MODULE_DEPTH + (BAT_T + BAT_CLEAR) / 2 - self.z_back / 2) \
                < LUG_T / 2 + SW_H / 2:
            w.append("Top keyring loop overlaps the switch slot.")
        return w

    def lug(self, mount):
        """(root point inside the body, hole centre) for a keyring loop, or None."""
        if mount == "top_loop":
            return (0.0, self.out_h / 2 - 3.0), (0.0, self.out_h / 2 + LUG_OFFSET)
        if mount == "corner_loop":
            cx, cy = -self.out_w / 2 + CORNER_R, self.out_h / 2 - CORNER_R
            k = (CORNER_R + LUG_OFFSET) / math.sqrt(2)
            return (cx, cy), (cx - k, cy + k)
        return None


def V(mm):
    return adsk.core.ValueInput.createByReal(mm * MM)


def P(x, y, z=0.0):
    return adsk.core.Point3D.create(x * MM, y * MM, z * MM)


def P2(x, y):
    return adsk.core.Point3D.create(x, y, 0)


class Part:
    """One component plus small helpers for sketching in model coordinates."""

    def __init__(self, root, name):
        occ = root.occurrences.addNewComponent(adsk.core.Matrix3D.create())
        self.comp = occ.component
        self.comp.name = name
        self.occ = occ

    def plane(self, axis, offset):
        c = self.comp
        base = {"x": c.yZConstructionPlane,
                "y": c.xZConstructionPlane,
                "z": c.xYConstructionPlane}[axis]
        if abs(offset) < 1e-9:
            return base
        # The origin planes' normals do not all point along +axis, so check and flip.
        for sign in (1.0, -1.0):
            inp = c.constructionPlanes.createInput()
            inp.setByOffset(base, V(sign * offset))
            pl = c.constructionPlanes.add(inp)
            o = pl.geometry.origin
            got = {"x": o.x, "y": o.y, "z": o.z}[axis] / MM
            if abs(got - offset) < 1e-3:
                try:
                    pl.isLightBulbOn = False
                except Exception:
                    pass
                return pl
            pl.deleteMe()
        raise RuntimeError("Could not place a %s plane at %.3f mm" % (axis, offset))

    def sketch(self, axis, offset, name=None):
        sk = self.comp.sketches.add(self.plane(axis, offset))
        if name:
            sk.name = name
        return sk

    def extrude(self, sk, op, dist=None, sym=None, bodies=None, name=None):
        profs = adsk.core.ObjectCollection.create()
        for i in range(sk.profiles.count):
            profs.add(sk.profiles.item(i))
        if profs.count == 0:
            raise RuntimeError("Sketch '%s' has no closed profile" % sk.name)
        ext = self.comp.features.extrudeFeatures
        inp = ext.createInput(profs, op)
        if sym is not None:
            inp.setSymmetricExtent(V(sym), True)
        else:
            inp.setOneSideExtent(
                adsk.fusion.DistanceExtentDefinition.create(V(dist)),
                adsk.fusion.ExtentDirections.PositiveExtentDirection)
        if bodies:
            inp.participantBodies = bodies
        feat = ext.add(inp)
        if name and feat.bodies.count:
            feat.bodies.item(0).name = name
        sk.isVisible = False
        return feat


# ---------- sketch geometry (all inputs are model-space mm) ----------

def _to_sk(sk, p):
    q = sk.modelToSketchSpace(P(*p))
    return q.x, q.y


def rrect(sk, a, b, r=0.0):
    """Axis-aligned rounded rectangle from two opposite model-space corners."""
    (ax, ay), (bx, by) = _to_sk(sk, a), _to_sk(sk, b)
    x0, x1 = sorted((ax, bx))
    y0, y1 = sorted((ay, by))
    lines = sk.sketchCurves.sketchLines
    r = r * MM
    half = min(x1 - x0, y1 - y0) / 2
    if r <= 1e-6:
        lines.addTwoPointRectangle(P2(x0, y0), P2(x1, y1))
        return
    if r > half - 1e-6:
        r = half  # stadium / circle ends
    segs = (((x0 + r, y0), (x1 - r, y0)), ((x1, y0 + r), (x1, y1 - r)),
            ((x1 - r, y1), (x0 + r, y1)), ((x0, y1 - r), (x0, y0 + r)))
    for (sx, sy), (ex, ey) in segs:
        if math.hypot(ex - sx, ey - sy) > 1e-6:
            lines.addByTwoPoints(P2(sx, sy), P2(ex, ey))
    arcs = sk.sketchCurves.sketchArcs
    q = math.pi / 2
    arcs.addByCenterStartSweep(P2(x1 - r, y0 + r), P2(x1 - r, y0), q)
    arcs.addByCenterStartSweep(P2(x1 - r, y1 - r), P2(x1, y1 - r), q)
    arcs.addByCenterStartSweep(P2(x0 + r, y1 - r), P2(x0 + r, y1), q)
    arcs.addByCenterStartSweep(P2(x0 + r, y0 + r), P2(x0, y0 + r), q)


def stadium(sk, a, b, r):
    """Slot shape: two half-circles of radius r centred on model points a and b."""
    (ax, ay), (bx, by) = _to_sk(sk, a), _to_sk(sk, b)
    r = r * MM
    L = math.hypot(bx - ax, by - ay)
    ux, uy = (bx - ax) / L, (by - ay) / L
    nx, ny = -uy, ux
    lines = sk.sketchCurves.sketchLines
    arcs = sk.sketchCurves.sketchArcs
    lines.addByTwoPoints(P2(ax - nx * r, ay - ny * r), P2(bx - nx * r, by - ny * r))
    arcs.addByCenterStartSweep(P2(bx, by), P2(bx - nx * r, by - ny * r), math.pi)
    lines.addByTwoPoints(P2(bx + nx * r, by + ny * r), P2(ax + nx * r, ay + ny * r))
    arcs.addByCenterStartSweep(P2(ax, ay), P2(ax + nx * r, ay + ny * r), math.pi)


def circle(sk, c, d):
    x, y = _to_sk(sk, c)
    sk.sketchCurves.sketchCircles.addByCenterRadius(P2(x, y), d / 2 * MM)


def poly(sk, pts):
    q = [_to_sk(sk, p) for p in pts]
    lines = sk.sketchCurves.sketchLines
    for i in range(len(q)):
        (sx, sy), (ex, ey) = q[i], q[(i + 1) % len(q)]
        lines.addByTwoPoints(P2(sx, sy), P2(ex, ey))


# ---------- edge finishing (cosmetic; failures are reported, not fatal) ----------

def _flat_face_at_z(body, z):
    for i in range(body.faces.count):
        f = body.faces.item(i)
        bb = f.boundingBox
        if abs(bb.minPoint.z - z * MM) < 1e-4 and abs(bb.maxPoint.z - z * MM) < 1e-4:
            return f
    return None


def _loop_edges(body, z, outer):
    f = _flat_face_at_z(body, z)
    col = adsk.core.ObjectCollection.create()
    if f is None:
        return col
    for i in range(f.loops.count):
        lp = f.loops.item(i)
        if lp.isOuter == outer:
            for j in range(lp.edges.count):
                col.add(lp.edges.item(j))
            if outer:
                break
    return col


def chamfer(comp, edges, d):
    if edges.count == 0:
        raise RuntimeError("no edges found")
    ch = comp.features.chamferFeatures
    try:
        inp = ch.createInput2()
        inp.chamferEdgeSets.addEqualDistanceChamferEdgeSet(edges, V(d), True)
    except AttributeError:
        inp = ch.createInput(edges, True)
        inp.setToEqualDistance(V(d))
    ch.add(inp)


def fillet(comp, edges, r):
    if edges.count == 0:
        raise RuntimeError("no edges found")
    fi = comp.features.filletFeatures
    inp = fi.createInput()
    try:
        inp.edgeSetInputs.addConstantRadiusEdgeSetInput(edges, V(r), True)
    except AttributeError:
        inp.addConstantRadiusEdgeSet(edges, V(r), True)
    fi.add(inp)


# ---------- parts ----------

def build_shell(root, d, notes, mount):
    s = Part(root, "Shell")

    sk = s.sketch("z", 0, "outline")
    rrect(sk, (-d.out_w / 2, -d.out_h / 2, 0), (d.out_w / 2, d.out_h / 2, 0), CORNER_R)
    body = s.extrude(sk, NEW, dist=d.shell_d, name="Shell").bodies.item(0)
    B = [body]

    # Keyring loop, centred in the depth of the closed box so it hangs straight.
    # Added before the cavity cut, which trims whatever part of it reaches inside.
    lug = d.lug(mount)
    if lug:
        (ax, ay), (hx, hy) = lug
        z0 = d.z_back / 2 - LUG_T / 2
        sk = s.sketch("z", z0, "keyring loop")
        stadium(sk, (ax, ay, z0), (hx, hy, z0), LUG_R)
        s.extrude(sk, JOIN, dist=LUG_T, bodies=B)
        sk = s.sketch("z", z0 - 0.5, "keyring hole")
        circle(sk, (hx, hy, z0 - 0.5), LUG_HOLE_D)
        s.extrude(sk, CUT, dist=LUG_T + 1, bodies=B)

    # Cavity for board + battery, open at the back.
    sk = s.sketch("z", BEZEL, "cavity")
    rrect(sk, (-d.cav_w / 2, -d.cav_h / 2, BEZEL), (d.cav_w / 2, d.cav_h / 2, BEZEL))
    s.extrude(sk, CUT, dist=d.shell_d - BEZEL + 1, bodies=B)

    # Screen window = active area minus WINDOW_INSET. The brim covers everything else.
    ws = AA - 2 * WINDOW_INSET
    sk = s.sketch("z", -0.5, "window")
    rrect(sk, (-ws / 2, AA_DY - ws / 2, -0.5), (ws / 2, AA_DY + ws / 2, -0.5), WINDOW_R)
    s.extrude(sk, CUT, dist=BEZEL + 1, bodies=B)

    # Screw bosses, behind the standoff plane so they never touch the PCB.
    sk = s.sketch("z", d.z_so, "bosses")
    for bx, by in d.bosses:
        circle(sk, (bx, by, d.z_so), 2 * d.boss_r)
    s.extrude(sk, JOIN, dist=d.shell_d - d.z_so, bodies=B)

    # 45-degree gussets under the bosses so they print without supports (front face down).
    protr = d.boss_inset + d.boss_r
    yi = d.cav_h / 2
    for bx, by in d.bosses:
        sg = 1 if by > 0 else -1
        sk = s.sketch("x", bx, "gusset")
        poly(sk, ((bx, sg * (yi + 0.3), d.z_so),
                  (bx, sg * (yi - protr), d.z_so),
                  (bx, sg * (yi + 0.3), d.z_so - protr - 0.3)))
        s.extrude(sk, JOIN, sym=2 * d.boss_r, bodies=B)

    # Pilot holes (self-tapping) or insert holes, from the back.
    z0 = d.shell_d - d.hole_depth
    sk = s.sketch("z", z0, "screw holes")
    for bx, by in d.bosses:
        circle(sk, (bx, by, z0), d.hole_d)
    s.extrude(sk, CUT, dist=d.hole_depth + 1, bodies=B)

    # Side vents: one cut through both side walls.
    zc = BEZEL + SIDE_VENT_ZC_FROM_GLASS
    x = d.out_w / 2
    sk = s.sketch("x", x, "side vents")
    for i in range(SIDE_VENT_COUNT):
        y = (i - (SIDE_VENT_COUNT - 1) / 2) * SIDE_VENT_PITCH
        rrect(sk, (x, y - SIDE_VENT_W / 2, zc - SIDE_VENT_LEN / 2),
              (x, y + SIDE_VENT_W / 2, zc + SIDE_VENT_LEN / 2), SIDE_VENT_W / 2)
    s.extrude(sk, CUT, sym=d.out_w + 2, bodies=B)

    # USB-C: port opening plus a shallow outside pocket for the plug's moulding.
    y = -d.out_h / 2
    zc = BEZEL + USB_Z_FROM_GLASS
    sk = s.sketch("y", y, "usb recess")
    rrect(sk, (USB_X - USB_RECESS_W / 2, y, zc - USB_RECESS_H / 2),
          (USB_X + USB_RECESS_W / 2, y, zc + USB_RECESS_H / 2), 1.5)
    s.extrude(sk, CUT, sym=2 * USB_RECESS_DEPTH, bodies=B)
    sk = s.sketch("y", y, "usb")
    rrect(sk, (USB_X - USB_W / 2, y, zc - USB_H / 2),
          (USB_X + USB_W / 2, y, zc + USB_H / 2), USB_H / 2)
    s.extrude(sk, CUT, sym=2 * (WALL + 0.6), bodies=B)

    # Power switch slot in the top wall, level with the battery bay.
    y = d.out_h / 2
    zc = d.z_so + (BAT_T + BAT_CLEAR) / 2
    sk = s.sketch("y", y, "switch slot")
    rrect(sk, (SW_X - SW_W / 2, y, zc - SW_H / 2), (SW_X + SW_W / 2, y, zc + SW_H / 2), 0.5)
    s.extrude(sk, CUT, sym=2 * (WALL + 0.6), bodies=B)

    # Cosmetic edges on the front face (also counters elephant's foot).
    for label, outer, size in (("window chamfer", False, WINDOW_CHAMFER),
                               ("front chamfer", True, FRONT_CHAMFER)):
        if size <= 0:
            continue
        try:
            chamfer(s.comp, _loop_edges(s.comp.bRepBodies.itemByName("Shell"), 0, outer), size)
        except Exception as e:  # noqa: BLE001
            notes.append("Skipped %s: %s" % (label, e))
    return s


def add_belt_clip(l, d, B):
    """Spring clip on the outside of the lid, open at the bottom, root at the top."""
    zb = d.z_back
    top = d.out_h / 2 - CLIP_EDGE
    root_bot = top - CLIP_ROOT
    tip = -d.out_h / 2 + CLIP_TIP_MARGIN
    zt = zb + CLIP_GAP

    sk = l.sketch("z", zb - 0.2, "clip root")
    rrect(sk, (-CLIP_W / 2, root_bot, zb - 0.2), (CLIP_W / 2, top, zb - 0.2))
    l.extrude(sk, JOIN, dist=0.2 + CLIP_GAP + CLIP_T, bodies=B)

    sk = l.sketch("z", zt, "clip tongue")
    rrect(sk, (-CLIP_W / 2, tip, zt), (CLIP_W / 2, root_bot + 0.5, zt), 1.0)
    l.extrude(sk, JOIN, dist=CLIP_T, bodies=B)

    # Ramp on the inside of the tip so the belt slides in.
    sk = l.sketch("x", 0, "clip lead-in")
    poly(sk, ((0, tip - 0.5, zt - 0.01),
              (0, tip + CLIP_LEAD, zt - 0.01),
              (0, tip - 0.5, zt + CLIP_LEAD_DEPTH)))
    l.extrude(sk, CUT, sym=CLIP_W + 2, bodies=B)


def build_lid(root, d, notes, mount):
    l = Part(root, "Lid")
    z = d.shell_d

    sk = l.sketch("z", z, "outline")
    rrect(sk, (-d.out_w / 2, -d.out_h / 2, z), (d.out_w / 2, d.out_h / 2, z), CORNER_R)
    body = l.extrude(sk, NEW, dist=LID_T, name="Lid").bodies.item(0)
    B = [body]

    # Posts press the standoff ends so the glass sits on the brim.
    zp = d.z_so - POST_PRELOAD
    sk = l.sketch("z", zp, "posts")
    for sx, sy in d.standoffs:
        circle(sk, (sx, sy, zp), POST_D)
    l.extrude(sk, JOIN, dist=z - zp + 0.2, bodies=B)

    zc = z - 0.5
    sk = l.sketch("z", zc, "screw clearance")
    for bx, by in d.bosses:
        circle(sk, (bx, by, zc), SCREW_CLEAR_D)
    l.extrude(sk, CUT, dist=LID_T + 1, bodies=B)

    zc = d.z_back - CBORE_DEPTH
    sk = l.sketch("z", zc, "counterbores")
    for bx, by in d.bosses:
        circle(sk, (bx, by, zc), CBORE_D)
    l.extrude(sk, CUT, dist=CBORE_DEPTH + 1, bodies=B)

    zc = z - 0.5
    sk = l.sketch("z", zc, "lid vents")
    for i in range(LID_VENT_COUNT):
        x = (i - (LID_VENT_COUNT - 1) / 2) * LID_VENT_PITCH
        rrect(sk, (x - LID_VENT_W / 2, -LID_VENT_LEN / 2, zc),
              (x + LID_VENT_W / 2, LID_VENT_LEN / 2, zc), LID_VENT_W / 2)
    l.extrude(sk, CUT, dist=LID_T + 1, bodies=B)

    if LID_FILLET > 0:
        try:
            fillet(l.comp, _loop_edges(l.comp.bRepBodies.itemByName("Lid"), d.z_back, True),
                   LID_FILLET)
        except Exception as e:  # noqa: BLE001
            notes.append("Skipped lid fillet: %s" % e)
    if mount == "belt_clip":
        add_belt_clip(l, d, [l.comp.bRepBodies.itemByName("Lid")])
    return l


def build_reference(root, d):
    r = Part(root, "Reference (do not print)")

    def box(name, cx, cy, w, h, z0, z1):
        sk = r.sketch("z", z0, name)
        rrect(sk, (cx - w / 2, cy - h / 2, z0), (cx + w / 2, cy + h / 2, z0))
        return r.extrude(sk, NEW, dist=z1 - z0, name=name)

    z_glass = BEZEL
    z_pcb_back = BEZEL + PCB_BACK_FROM_GLASS
    box("LCD panel", 0, 0, 26.16, 29.22, z_glass, z_glass + 1.5)
    box("PCB", 0, 0, PCB_W, PCB_H, z_pcb_back - 1.2, z_pcb_back)
    box("USB-C", USB_X, -PCB_H / 2 + 3.65, 8.94, 7.3,
        BEZEL + USB_Z_FROM_GLASS - 1.6, BEZEL + USB_Z_FROM_GLASS + 1.6)
    sk = r.sketch("z", z_pcb_back, "standoffs")
    for sx, sy in d.standoffs:
        circle(sk, (sx, sy, z_pcb_back), STANDOFF_HEX)
    r.extrude(sk, NEW, dist=d.z_so - z_pcb_back, name="Standoffs")
    box("Battery", 0, 0, BAT_X, BAT_Y, d.z_so + 0.5, d.z_so + 0.5 + BAT_T)

    for i in range(r.comp.bRepBodies.count):
        try:
            r.comp.bRepBodies.item(i).opacity = 0.35
        except Exception:
            pass
    return r


def export_stl(design, parts, folder):
    os.makedirs(folder, exist_ok=True)
    em = design.exportManager
    written = []
    for comp, body_name, file_name in parts:
        body = comp.bRepBodies.itemByName(body_name)
        path = os.path.join(folder, file_name)
        opts = em.createSTLExportOptions(body, path)
        opts.meshRefinement = adsk.fusion.MeshRefinementSettings.MeshRefinementHigh
        em.execute(opts)
        written.append(path)
    return written


def run(context):
    ui = None
    try:
        app = adsk.core.Application.get()
        ui = app.userInterface
        d = Dims()
        notes = []
        written = []
        here = os.path.dirname(os.path.abspath(__file__))

        # One design (Fusion tab) per mount variant.
        for mount in VARIANTS:
            app.documents.add(adsk.core.DocumentTypes.FusionDesignDocumentType)
            design = adsk.fusion.Design.cast(app.activeProduct)
            design.designType = adsk.fusion.DesignTypes.ParametricDesignType
            design.fusionUnitsManager.distanceDisplayUnits = \
                adsk.fusion.DistanceUnits.MillimeterDistanceUnits
            root = design.rootComponent
            root.name = "Enclosure V1 - " + mount

            vnotes = []
            shell = build_shell(root, d, vnotes, mount)
            lid = build_lid(root, d, vnotes, mount)
            if BUILD_REFERENCE:
                build_reference(root, d)
            notes += ["[%s] %s" % (mount, n) for n in vnotes]

            if EXPORT_STL:
                written += export_stl(design, (
                    (shell.comp, "Shell", "v1_%s_shell.stl" % mount),
                    (lid.comp, "Lid", "v1_%s_lid.stl" % mount),
                ), os.path.join(here, "stl"))
            app.activeViewport.fit()

        msg = ["Spotify Display enclosure V1: " + ", ".join(VARIANTS),
               "Outside: %.2f x %.2f x %.2f mm (W x H x D)" % (d.out_w, d.out_h, d.z_back),
               "Screws: 2x M2 x 6 %s" % ("machine + heat-set inserts" if HEAT_INSERTS
                                          else "self-tapping"),
               ""]
        msg += ["WARNING: " + w for w in d.warnings()]
        msg += notes
        msg += ["STL: " + p for p in written]
        ui.messageBox("\n".join(msg))
    except Exception:  # noqa: BLE001
        if ui:
            ui.messageBox("Enclosure script failed:\n{}".format(traceback.format_exc()))
