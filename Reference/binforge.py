#!/usr/bin/env python3
"""
binforge.py - reference implementation of the tool-to-bin pipeline, written to be
ported to Swift line by line. No geometry libraries: numpy for arrays, cv2 only
for the three image steps that Vision / Core Image do on iOS (subject mask,
dilate-for-clearance, contour trace). Validation with trimesh is separate.

Pipeline
  1. mask (H x W, 0/255)                      iOS: VNGenerateForegroundInstanceMaskRequest
  2. dilate by clearance_px                   iOS: CIMorphologyMaximum (radius = clearance_mm / mm_per_px)
  3. outer contour -> polygon in px           iOS: VNDetectContoursRequest (outermost contour)
  4. simplify + scale to mm                   Douglas-Peucker; mm_per_px from the calibration quad
  5. choose bin size (N x M grid units, H units tall) from the polygon's bounding box
  6. build meshes: feet (one per cell, lofted profile) + body with blind pocket
  7. write binary STL                         iOS: FileManager + ShareLink

Gridfinity numbers (from gridfinity-rebuilt-openscad src/core/standard.scad):
  grid 42, bin top 41.5 (0.5 gap), height unit 7, base profile heights 0.8 (45deg),
  1.8 (vertical), 2.15 (45deg) = 4.95, corner radius 3.75 top / 1.6 bottom,
  magnet hole r 3.25 depth 2.4, min wall 0.95, stacking lip 0.7/1.8/1.9.
"""
import math, struct, sys
import numpy as np

GRID = 42.0
BIN_TOP = 41.5
UNIT_H = 7.0
PROFILE = [(0.0, 2.95), (0.8, 2.15), (2.6, 2.15), (4.95, 0.0), (5.2, 0.0)]  # (z, inset); last ring overlaps 0.25 mm into the body so no faces coincide
R_TOP = 3.75
WALL_MIN = 0.95
FLOOR_ABOVE_BASE = 1.2      # pocket floor sits this far above the 7 mm base
MAGNET_R, MAGNET_D = 3.25, 2.4

# ---------- 2D helpers ----------

def rounded_rect(cx, cy, w, h, r, seg=6):
    """Counter-clockwise rounded rectangle centred at (cx, cy)."""
    r = max(0.05, min(r, w / 2, h / 2))
    pts = []
    corners = [(cx + w/2 - r, cy + h/2 - r, 0), (cx - w/2 + r, cy + h/2 - r, 90),
               (cx - w/2 + r, cy - h/2 + r, 180), (cx + w/2 - r, cy - h/2 + r, 270)]
    for (x, y, a0) in corners:
        for i in range(seg + 1):
            a = math.radians(a0 + 90 * i / seg)
            pts.append((x + r * math.cos(a), y + r * math.sin(a)))
    return dedupe(pts)

def dedupe(pts, eps=1e-6):
    out = []
    for p in pts:
        if not out or abs(out[-1][0]-p[0]) > eps or abs(out[-1][1]-p[1]) > eps:
            out.append(p)
    if len(out) > 1 and abs(out[0][0]-out[-1][0]) < eps and abs(out[0][1]-out[-1][1]) < eps:
        out.pop()
    return out

def area(poly):
    a = 0.0
    for i in range(len(poly)):
        x1, y1 = poly[i]; x2, y2 = poly[(i + 1) % len(poly)]
        a += x1 * y2 - x2 * y1
    return a / 2

def ccw(poly):
    return poly if area(poly) > 0 else poly[::-1]

def douglas_peucker(pts, eps):
    if len(pts) < 3:
        return pts
    def dist(p, a, b):
        ax, ay = a; bx, by = b; px, py = p
        dx, dy = bx - ax, by - ay
        if dx == dy == 0:
            return math.hypot(px - ax, py - ay)
        t = max(0, min(1, ((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy)))
        return math.hypot(px - (ax + t * dx), py - (ay + t * dy))
    dmax, idx = 0, 0
    for i in range(1, len(pts) - 1):
        d = dist(pts[i], pts[0], pts[-1])
        if d > dmax:
            dmax, idx = d, i
    if dmax > eps:
        return douglas_peucker(pts[:idx + 1], eps)[:-1] + douglas_peucker(pts[idx:], eps)
    return [pts[0], pts[-1]]

def simplify_closed(poly, eps):
    # split at the farthest point from pts[0] so both halves are open chains
    far = max(range(len(poly)), key=lambda i: math.hypot(poly[i][0]-poly[0][0], poly[i][1]-poly[0][1]))
    a = douglas_peucker(poly[:far + 1], eps)
    b = douglas_peucker(poly[far:] + [poly[0]], eps)
    return dedupe(a[:-1] + b[:-1])

# ---------- ear clipping (simple polygon, CCW) ----------

def _inside(p, a, b, c):
    def s(p1, p2, p3):
        return (p1[0]-p3[0])*(p2[1]-p3[1]) - (p2[0]-p3[0])*(p1[1]-p3[1])
    d1, d2, d3 = s(p, a, b), s(p, b, c), s(p, c, a)
    return not ((d1 < 0 or d2 < 0 or d3 < 0) and (d1 > 0 or d2 > 0 or d3 > 0))

def earclip(poly):
    """Return list of index triangles for a simple CCW polygon (O(n^2), fine for < 2000 pts)."""
    n = len(poly)
    idx = list(range(n))
    tris = []
    guard = 0
    while len(idx) > 3 and guard < 10 * n:
        guard += 1
        found = False
        for k in range(len(idx)):
            i0, i1, i2 = idx[k - 1], idx[k], idx[(k + 1) % len(idx)]
            a, b, c = poly[i0], poly[i1], poly[i2]
            cross = (b[0]-a[0])*(c[1]-a[1]) - (b[1]-a[1])*(c[0]-a[0])
            if cross <= 1e-12:
                continue  # reflex or degenerate
            if any(_inside(poly[j], a, b, c) for j in idx if j not in (i0, i1, i2)):
                continue
            tris.append((i0, i1, i2)); idx.pop(k); found = True
            break
        if not found:  # numerical trouble: clip the least-bad ear
            k = 0
            tris.append((idx[k - 1], idx[k], idx[(k + 1) % len(idx)])); idx.pop(k)
    if len(idx) == 3:
        tris.append(tuple(idx))
    return tris

def bridge_hole(outer, hole):
    """Merge one CW hole into a CCW outer polygon with a bridge edge -> simple polygon.
    Classic approach: connect the hole's rightmost vertex to the closest visible outer vertex."""
    hi = max(range(len(hole)), key=lambda i: hole[i][0])
    hp = hole[hi]
    # nearest outer vertex to the right-ish of hp (good enough for convex-ish outers like rounded rects)
    oi = min(range(len(outer)), key=lambda i: (outer[i][0] < hp[0], math.hypot(outer[i][0]-hp[0], outer[i][1]-hp[1])))
    merged = outer[:oi + 1] + [hole[(hi + k) % len(hole)] for k in range(len(hole))] + [hole[hi]] + outer[oi:]
    return merged

# ---------- mesh assembly ----------

class Mesh:
    def __init__(self):
        self.tris = []  # list of ((x,y,z),(x,y,z),(x,y,z)), outward CCW
    def add(self, a, b, c):
        self.tris.append((a, b, c))
    def cap(self, poly2d, z, up=True):
        for (i, j, k) in earclip(poly2d):
            a, b, c = (poly2d[i][0], poly2d[i][1], z), (poly2d[j][0], poly2d[j][1], z), (poly2d[k][0], poly2d[k][1], z)
            self.add(a, b, c) if up else self.add(a, c, b)
    def walls(self, lower, upper, outward=True):
        """Quads between two rings with equal point counts; lower/upper are lists of (x,y,z)."""
        n = len(lower)
        for i in range(n):
            a, b = lower[i], lower[(i + 1) % n]
            c, d = upper[(i + 1) % n], upper[i]
            if outward:
                self.add(a, b, c); self.add(a, c, d)
            else:
                self.add(a, c, b); self.add(a, d, c)
    def extend(self, other):
        self.tris.extend(other.tris)
    def write_stl(self, path, name="binforge"):
        with open(path, "wb") as f:
            f.write(name.encode().ljust(80, b"\0"))
            f.write(struct.pack("<I", len(self.tris)))
            for (a, b, c) in self.tris:
                u = np.subtract(b, a); v = np.subtract(c, a)
                nrm = np.cross(u, v); ln = np.linalg.norm(nrm)
                nrm = nrm / ln if ln > 0 else (0, 0, 0)
                f.write(struct.pack("<3f", *nrm))
                for p in (a, b, c):
                    f.write(struct.pack("<3f", *p))
                f.write(struct.pack("<H", 0))

def foot(cx, cy, mesh, magnet_holes=False):
    """One gridfinity foot: loft of rounded rects through PROFILE, closed top and bottom."""
    rings = []
    for (z, inset) in PROFILE:
        w = BIN_TOP - 2 * inset
        r = max(R_TOP - inset, 0.5)
        ring = [(x, y, z) for (x, y) in ccw(rounded_rect(cx, cy, w, w, r))]
        rings.append(ring)
    mesh.cap([(x, y) for (x, y, z) in rings[0]], rings[0][0][2], up=False)
    for lo, hi in zip(rings, rings[1:]):
        mesh.walls(lo, hi, outward=True)
    mesh.cap([(x, y) for (x, y, z) in rings[-1]], rings[-1][0][2], up=True)

def body(n, m, height_units, pocket, mesh):
    """Bin body from z=4.95 to H with a blind pocket. pocket: CCW polygon in mm (bin-local coords, origin at bin centre)."""
    W, D = n * GRID - 0.5, m * GRID - 0.5
    z0, H = 4.95, height_units * UNIT_H
    zf = UNIT_H + FLOOR_ABOVE_BASE
    outer = ccw(rounded_rect(0, 0, W, D, R_TOP))
    hole = ccw(pocket)[::-1]  # CW for bridging
    top = bridge_hole(outer, hole)
    # bottom cap (solid), outer walls
    mesh.cap(outer, z0, up=False)
    mesh.walls([(x, y, z0) for (x, y) in outer], [(x, y, H) for (x, y) in outer], outward=True)
    # top annulus
    mesh.cap(top, H, up=True)
    # pocket walls (inward-facing) and floor
    pk = ccw(pocket)
    mesh.walls([(x, y, zf) for (x, y) in pk], [(x, y, H) for (x, y) in pk], outward=False)
    mesh.cap(pk, zf, up=True)

def build_bin(pocket_mm, height_units=3, clearance_from_wall=WALL_MIN + 0.6):
    """pocket_mm: CCW polygon (mm) of the dilated tool outline, any origin. Returns (Mesh, n, m, info)."""
    xs = [p[0] for p in pocket_mm]; ys = [p[1] for p in pocket_mm]
    bw, bh = max(xs) - min(xs), max(ys) - min(ys)
    n = max(1, math.ceil((bw + 2 * clearance_from_wall + 0.5) / GRID))
    m = max(1, math.ceil((bh + 2 * clearance_from_wall + 0.5) / GRID))
    # centre the outline in the bin
    cx, cy = (max(xs) + min(xs)) / 2, (max(ys) + min(ys)) / 2
    pocket = [(x - cx, y - cy) for (x, y) in pocket_mm]
    mesh = Mesh()
    for i in range(n):
        for j in range(m):
            fx = -(n - 1) * GRID / 2 + i * GRID
            fy = -(m - 1) * GRID / 2 + j * GRID
            foot(fx, fy, mesh)
    body(n, m, height_units, pocket, mesh)
    return mesh, n, m, dict(tool_w=bw, tool_h=bh, bin_w=n * GRID - 0.5, bin_d=m * GRID - 0.5, height=height_units * UNIT_H)

# ---------- optional finger-notch extension (Swift: FingerNotch.swift) ----------

def point_in_polygon(p, polygon):
    inside = False
    for i, a in enumerate(polygon):
        b = polygon[(i + 1) % len(polygon)]
        if (a[1] > p[1]) != (b[1] > p[1]) and p[0] < (b[0]-a[0])*(p[1]-a[1])/(b[1]-a[1])+a[0]:
            inside = not inside
    return inside

def nearest_pocket_point(p, polygon):
    best, distance = polygon[0], float('inf')
    for i, a in enumerate(polygon):
        b = polygon[(i+1) % len(polygon)]
        d = (b[0]-a[0], b[1]-a[1])
        length = d[0]**2 + d[1]**2
        if length < 1e-12:
            continue
        t = min(1, max(0, ((p[0]-a[0])*d[0]+(p[1]-a[1])*d[1])/length))
        q = (a[0]+t*d[0], a[1]+t*d[1])
        candidate = (p[0]-q[0])**2 + (p[1]-q[1])**2
        if candidate < distance:
            best, distance = q, candidate
    return best

def split_notch_edges(a, b):
    def cross(p, q): return p[0]*q[1]-p[1]*q[0]
    def sub(p, q): return (p[0]-q[0], p[1]-q[1])
    sa, sb = [[(0, p)] for p in a], [[(0, p)] for p in b]
    intersections = 0
    for i, p in enumerate(a):
        r = sub(a[(i+1) % len(a)], p)
        for j, q in enumerate(b):
            s = sub(b[(j+1) % len(b)], q)
            denominator = cross(r, s)
            if abs(denominator) < 1e-10: continue
            t, u = cross(sub(q, p), s)/denominator, cross(sub(q, p), r)/denominator
            if 0 <= t <= 1 and 0 <= u <= 1:
                point = (p[0]+t*r[0], p[1]+t*r[1])
                sa[i].append((t, point)); sb[j].append((u, point))
                intersections += 1
    if intersections < 2: return None
    def edges(splits, other):
        ring = dedupe([p for split in splits for _, p in sorted(split, key=lambda item: item[0])])
        return [(p, ring[(i+1) % len(ring)], point_in_polygon(
            ((p[0]+ring[(i+1) % len(ring)][0])/2, (p[1]+ring[(i+1) % len(ring)][1])/2), other))
            for i, p in enumerate(ring)]
    return edges(sa, b), edges(sb, a)

def notch_loops(edges):
    remaining, loops = list(edges), []
    while remaining:
        first = remaining.pop(0)
        ring, end = [first[0]], first[1]
        while math.dist(end, first[0]) > 1e-6:
            ring.append(end)
            index = next((i for i, edge in enumerate(remaining) if math.dist(edge[0], end) < 1e-6), None)
            if index is None: return None
            end = remaining.pop(index)[1]
        if len(ring) < 3 or area(ring) <= 1e-6: return None
        loops.append(ring)
    return loops

def notched_body(width, depth, z0, top, floor_z, corner_radius, pocket, notch, minimum_floor):
    """Optional two-depth pocket, without changing the legacy builder. notch=(x,y,width,depth).
    Returns None for unsafe placement or unsupported topology. All coordinates are bin-local.
    """
    x, y, diameter, cut_depth = notch
    if not all(math.isfinite(v) for v in notch) or not 8 <= diameter <= 40 or cut_depth < 1 or top <= minimum_floor:
        return None
    circle = [(x+diameter/2*math.cos(2*math.pi*i/48), y+diameter/2*math.sin(2*math.pi*i/48)) for i in range(48)]
    safe = rounded_rect(0, 0, width-2*WALL_MIN, depth-2*WALL_MIN, max(0.05, corner_radius-WALL_MIN))
    if not all(point_in_polygon(p, safe) for p in circle): return None
    split = split_notch_edges(ccw(pocket), circle)
    if split is None: return None
    tool_edges, notch_edges = split
    exposed = [e for e in tool_edges+notch_edges if not e[2]]
    union = notch_loops(exposed)
    if union is None or len(union) != 1: return None
    notch_floor = max(minimum_floor, top-cut_depth)
    low, high = min(floor_z, notch_floor), max(floor_z, notch_floor)
    outer = ccw(rounded_rect(0, 0, width, depth, corner_radius))
    mesh = Mesh()
    def cap(poly, z, up=True):
        triangles = earclip(poly)
        areas = [area([poly[i], poly[j], poly[k]]) for i, j, k in triangles]
        if len(triangles) != len(poly)-2 or any(a <= 1e-10 for a in areas) or abs(sum(areas)-area(poly)) >= 1e-5:
            return False
        mesh.cap(poly, z, up)
        return True
    def walls(edges, bottom, top):
        if top-bottom <= 1e-8: return
        for p, q, _ in edges:
            a, b = (*p, bottom), (*q, bottom)
            c, d = (*q, top), (*p, top)
            mesh.add(a, c, b); mesh.add(a, d, c)
    if not cap(outer, z0, False): return None
    mesh.walls([(*p, z0) for p in outer], [(*p, top) for p in outer], True)
    if not cap(bridge_hole(outer, union[0][::-1]), top): return None
    walls(exposed, high, top)
    if high-low < 1e-8:
        if not cap(union[0], low): return None
    else:
        deep, shallow = (tool_edges, notch_edges) if floor_z < notch_floor else (notch_edges, tool_edges)
        walls(deep, low, high)
        if not cap([e[0] for e in deep], low): return None
        ledges = notch_loops([e for e in shallow if not e[2]] + [(b, a, False) for a, b, inside in deep if inside])
        if ledges is None: return None
        for ledge in ledges:
            if not cap(ledge, high): return None
    return mesh

# ---------- image side (what Vision / Core Image do on the phone) ----------

def outline_from_mask(mask_u8, mm_per_px, clearance_mm=0.6, simplify_mm=0.25):
    import cv2
    k = max(1, int(round(clearance_mm / mm_per_px)))
    dil = cv2.dilate(mask_u8, np.ones((2 * k + 1, 2 * k + 1), np.uint8))
    cnts, _ = cv2.findContours(dil, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_NONE)
    c = max(cnts, key=cv2.contourArea).reshape(-1, 2)
    poly = [(float(x) * mm_per_px, -float(y) * mm_per_px) for (x, y) in c]  # flip y: image down -> mm up
    poly = simplify_closed(dedupe(poly), simplify_mm)
    return ccw(poly)

if __name__ == "__main__":
    import cv2
    # synthetic "wrench" mask at 10 px/mm on a 200 x 100 mm sheet
    ppm = 10.0
    img = np.zeros((1000, 2000), np.uint8)
    cv2.rectangle(img, (500, 470), (1500, 530), 255, -1)           # 100 x 6 mm handle
    cv2.circle(img, (450, 500), 120, 255, -1)                        # 24 mm head
    cv2.rectangle(img, (380, 440), (470, 560), 0, -1)                # open jaw notch
    cv2.circle(img, (1560, 500), 90, 255, -1)                        # 18 mm ring end
    cv2.circle(img, (1560, 500), 35, 0, -1)                          # hole (ignored: outer contour only)
    poly = outline_from_mask(img, 1 / ppm, clearance_mm=0.6)
    mesh, n, m, info = build_bin(poly, height_units=3)
    out = sys.argv[1] if len(sys.argv) > 1 else "wrench_bin.stl"
    mesh.write_stl(out)
    print(f"outline points: {len(poly)}  bin: {n}x{m} units, {info['bin_w']}x{info['bin_d']}x{info['height']} mm, tool {info['tool_w']:.1f}x{info['tool_h']:.1f} mm, triangles {len(mesh.tris)} -> {out}")
