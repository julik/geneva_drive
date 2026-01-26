# Geneva Drive Animation - Session Learnings

## Overview
Built an animated SVG of a 4-slot Geneva drive (Maltese cross) mechanism with geometrically accurate motion and interactive controls.

## Key Technical Insights

### 1. Geneva Drive Kinematics
CSS animations cannot properly represent Geneva drive motion because the step rotation depends on the pin-slot geometry. The correct approach uses JavaScript with `requestAnimationFrame`:

```javascript
// During engagement (pin inside Geneva wheel radius):
if (dist < R) {
  const angleToPin = Math.atan2(dy, dx);
  genevaAngle = angleToPin - Math.PI;
}
// When disengaged, Geneva wheel holds its position (no snapping needed)
```

The Geneva wheel rotates such that its slot always points at the pin during engagement. When the pin exits, the wheel simply holds its last position.

### 2. SVG Path Construction for Geneva Wheel

The Geneva wheel shape requires:
- **Even-odd fill rule** for cutting out slots from the main shape
- **Circular arcs (A command)** for concave indentations between arms
- **Pill-shaped slots** with semicircular ends on both inner and outer sides

Key path elements:
```javascript
// Concave arc between arms (matches driver disc radius)
d += `A ${driverRadius} ${driverRadius} 0 0 0 ${x} ${y} `;

// Outer edge arc (at Geneva wheel radius)
d += `A ${R} ${R} 0 0 1 ${x} ${y} `;

// Slot cutout with rounded ends
d += `M ${i1x} ${i1y} L ${o1x} ${o1y} `;
d += `A ${hw} ${hw} 0 0 1 ${o2x} ${o2y} `;  // outer semicircle
d += `L ${i2x} ${i2y} `;
d += `A ${hw} ${hw} 0 0 0 ${i1x} ${i1y} Z `; // inner semicircle
```

### 3. Geometry Calculations

- **Slot angular half-width**: `Math.asin(slotHalfWidth / R)` - determines where slots intersect outer edge
- **Arm extension**: Small offset past slot edges for narrow arm tips
- **Concave arc radius**: Should equal driver disc radius for proper clearance

### 4. SVG Arc Command Parameters
`A rx ry rotation large-arc-flag sweep-flag x y`

- `sweep-flag=0`: Counter-clockwise (concave, curves inward)
- `sweep-flag=1`: Clockwise (convex, curves outward)
- Arc radius must be >= half the chord length between endpoints

### 5. Animation Loop Structure
```javascript
function animate(timestamp) {
  const dt = timestamp - lastTime;
  lastTime = timestamp;

  // Update driver angle based on RPM
  driverAngle += (2 * Math.PI * rpm / 60000) * dt;

  // Calculate pin position
  const pinX = Dx + r * Math.cos(driverAngle);
  const pinY = Dy + r * Math.sin(driverAngle);

  // Check engagement and update Geneva angle
  const dist = Math.sqrt((pinX - Gx)**2 + (pinY - Dy)**2);
  if (dist < R) {
    genevaAngle = Math.atan2(pinY - Dy, pinX - Gx) - Math.PI;
  }

  // Apply transforms
  driverGroup.setAttribute('transform', `rotate(${degrees}, ${Dx}, ${Dy})`);
  genevaGroup.setAttribute('transform', `rotate(${degrees}, ${Gx}, ${Dy})`);

  requestAnimationFrame(animate);
}
```

## Design Decisions

1. **No CSS animations**: JavaScript provides accurate geometric motion
2. **No snapping on disengage**: Geneva wheel naturally holds position
3. **Layering**: Geneva wheel rendered on top, overlapping driver
4. **Colors**: Driver disc full black (#000), Geneva wheel 75% black (#404040)
5. **Interactive sliders**: Speed, center distance, Geneva radius, pin offset

## File Structure
- Single HTML file with embedded CSS and JavaScript
- No external dependencies or libraries
- SVG with transform-based animation

## Potential Improvements
- Add locking disc visualization (prevents Geneva rotation when disengaged)
- Configurable number of slots (3, 4, 6, 8)
- Export animation as video/GIF
- Add measurement overlays showing geometric relationships
