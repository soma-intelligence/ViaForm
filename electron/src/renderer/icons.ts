// ViaForm's own toolbar icons: simple 24 px strokes, drawn for this app.
const P: Record<string, string> = {
  select: "M5 3l13 8-6 1.5L9 19z",
  box: "M12 3l8 4.5v9L12 21l-8-4.5v-9zM4 7.5l8 4.5 8-4.5M12 12v9",
  cylinder: "M5 6c0-1.7 3.1-3 7-3s7 1.3 7 3v12c0 1.7-3.1 3-7 3s-7-1.3-7-3zM5 6c0 1.7 3.1 3 7 3s7-1.3 7-3",
  sphere: "M12 3a9 9 0 1 0 0 18a9 9 0 1 0 0-18zM3 12c0 2.2 4 4 9 4s9-1.8 9-4",
  union: "M4 8h9v4h7v8H11v-4H4z",
  subtract: "M4 4h12v12H4zM10 10h10v10H10",
  trash: "M5 7h14M10 7V4h4v3M7 7l1 13h8l1-13",
  board: "M3 6h18v12H3zM7 10h2v2H7zM15 12h2v2h-2zM9 11h6",
  mount: "M4 14h16v4H4zM8 14V9h8v5M12 4v5M9.5 6.5L12 9l2.5-2.5",
  fit: "M4 9V4h5M20 9V4h-5M4 15v5h5M20 15v5h-5",
  search: "M10.5 4a6.5 6.5 0 1 0 0 13a6.5 6.5 0 1 0 0-13zM15.5 15.5L20 20",
  undo: "M9 7H4V2M4 7c2-3 5-4 8-4a8 8 0 1 1-7.5 10.5",
  redo: "M15 7h5V2M20 7c-2-3-5-4-8-4a8 8 0 1 0 7.5 10.5",
  resistor: "M3 12h4M17 12h4M7 9h10v6H7z",
  capacitor: "M3 12h7M14 12h7M10 6v12M14 6v12",
  led: "M3 12h6M15 12h6M9 7l6 5-6 5zM15 7v10M13 5l2-2M16 6l2-2",
  connector: "M5 6h8v12H5zM13 9h6M13 15h6M8 9.5h2M8 14.5h2",
  wire: "M5 18a2 2 0 1 0 0.1 0M19 6a2 2 0 1 0 0.1 0M6.5 17L12 17V7h5.5",
  update: "M20 11a8 8 0 0 0-14.5-4.5L4 8M4 4v4h4M4 13a8 8 0 0 0 14.5 4.5L20 16M20 20v-4h-4",
  route: "M5 19a2 2 0 1 0 0.1 0M19 5a2 2 0 1 0 0.1 0M5 17V11h14V7",
  routeAll: "M4 18a1.5 1.5 0 1 0 0.1 0M20 6a1.5 1.5 0 1 0 0.1 0M4 16.5V12h16V7.5M4 8a1.5 1.5 0 1 0 0.1 0M20 16a1.5 1.5 0 1 0 0.1 0M4 9.5V12M20 12v4",
  rotate: "M20 12a8 8 0 1 1-3-6.2M20 4v4h-4",
  export: "M12 15V3M7 8l5-5 5 5M4 14v6h16v-6",
  cube3d: "M12 3l8 4.5v9L12 21l-8-4.5v-9zM12 12l8-4.5M12 12L4 7.5M12 12v9",
  check: "M5 12l4 4 10-10",
  warn: "M12 3l10 18H2zM12 10v5M12 18v.5",
  cpu: "M7 7h10v10H7zM10 3v4M14 3v4M10 17v4M14 17v4M3 10h4M3 14h4M17 10h4M17 14h4",
  link: "M10 14a4 4 0 0 0 5.7 0l3-3a4 4 0 0 0-5.7-5.7l-1 1M14 10a4 4 0 0 0-5.7 0l-3 3a4 4 0 0 0 5.7 5.7l1-1",
  part: "M4 7l8-4 8 4v10l-8 4-8-4z",
  net: "M6 6a2 2 0 1 0 0.1 0M18 6a2 2 0 1 0 0.1 0M12 18a2 2 0 1 0 0.1 0M7.5 7.5l3.5 9M16.5 7.5l-3.5 9",
  top: "M4 8l8-4 8 4-8 4z",
  front: "M6 6h12v12H6z",
  right: "M8 4l10 4v12L8 16z",
  home: "M4 11l8-7 8 7M6 9.5V20h12V9.5",
};

export function icon(name: string, size = 20): string {
  const d = P[name] ?? P.part;
  return `<svg width="${size}" height="${size}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="${d}"/></svg>`;
}
