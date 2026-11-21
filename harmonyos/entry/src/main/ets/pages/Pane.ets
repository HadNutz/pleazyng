// All coordinates in this module are logical and relative to the player page.
export class Pane {
  left: number;
  top: number;
  width: number;
  height: number;
  constructor(left: number, top: number, width: number, height: number) {
    this.left = left;
    this.top = top;
    this.width = width;
    this.height = height;
  }
}

// Process each crease independently on devices with more than two panels.
// A crease outside this window cannot create an extra pane in split-screen.
export function splitPanes(view: Pane, creases: Pane[]): Pane[] {
  let panes: Pane[] = [view];
  for (let gap of creases) {
    const next: Pane[] = [];
    for (let r of panes) {
      const right = r.left + r.width;
      const bottom = r.top + r.height;
      if (gap.top <= r.top + 1 && gap.top + gap.height >= bottom - 1 &&
          gap.left > r.left && gap.left + gap.width < right) {
        next.push(new Pane(r.left, r.top, gap.left - r.left, r.height));
        next.push(new Pane(gap.left + gap.width, r.top, right - gap.left - gap.width, r.height));
      } else if (gap.left <= r.left + 1 && gap.left + gap.width >= right - 1 &&
          gap.top > r.top && gap.top + gap.height < bottom) {
        next.push(new Pane(r.left, r.top, r.width, gap.top - r.top));
        next.push(new Pane(r.left, gap.top + gap.height, r.width, bottom - gap.top - gap.height));
      } else {
        next.push(r);
      }
    }
    panes = next;
  }
  return panes;
}
