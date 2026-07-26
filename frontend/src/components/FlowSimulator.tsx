"use client";

import {
  useEffect,
  useMemo,
  useRef,
  useState,
  type PointerEvent as ReactPointerEvent,
} from "react";
import type { DemoCase } from "@/data/cases";

/** Default left-to-right execution order of the seven flow nodes */
const DEFAULT_ORDER = ["sign", "unlock", "before", "l1", "l2", "decide", "out"] as const;

type NodeDef = {
  id: string;
  title: string;
  subtitle: string;
  kind: "trigger" | "process" | "decision" | "action";
};

type Point = { x: number; y: number };

/** Static nodes 1–6 (node 7 / outcome is built dynamically from the case) */
const BASE_NODES: NodeDef[] = [
  {
    id: "sign",
    title: "User signs",
    subtitle: "Swap trigger",
    kind: "trigger",
  },
  {
    id: "unlock",
    title: "PoolManager.unlock",
    subtitle: "unlockCallback",
    kind: "process",
  },
  {
    id: "before",
    title: "beforeSwap",
    subtitle: "AML Hook intercepts",
    kind: "process",
  },
  {
    id: "l1",
    title: "Layer 1 · Sanctions",
    subtitle: "OFAC on-chain",
    kind: "process",
  },
  {
    id: "l2",
    title: "Layer 2 · Agent score",
    subtitle: "Compliance Oracle",
    kind: "process",
  },
  {
    id: "decide",
    title: "Layer 3 · Decision",
    subtitle: "Allow / Fee / Block",
    kind: "decision",
  },
];

const NODE_W = 180;
const NODE_H = 124;
const GAP_X = 96;
const GAP_Y = 88;
const START_X = 48;
const START_Y = 56;

/**
 * Default grid slots: steps 1–4 on the top row, steps 5–7 on the bottom row
 * so orthogonal connectors do not cross.
 */
const DEFAULT_SLOTS: Record<string, { col: number; row: number }> = {
  sign: { col: 0, row: 0 },
  unlock: { col: 1, row: 0 },
  before: { col: 2, row: 0 },
  l1: { col: 3, row: 0 },
  l2: { col: 2, row: 1 },
  decide: { col: 3, row: 1 },
  out: { col: 4, row: 1 },
};

/**
 * Converts a grid column/row slot into canvas pixel coordinates.
 */
function slotPoint(col: number, row: number): Point {
  return {
    x: START_X + col * (NODE_W + GAP_X),
    y: START_Y + row * (NODE_H + GAP_Y),
  };
}

/**
 * Builds the initial absolute positions map for every node id.
 */
function initialPositions(ids: string[]): Record<string, Point> {
  const positions: Record<string, Point> = {};
  ids.forEach((id) => {
    const slot = DEFAULT_SLOTS[id] ?? { col: 0, row: 0 };
    positions[id] = slotPoint(slot.col, slot.row);
  });
  return positions;
}

/**
 * Builds an orthogonal SVG path between two nodes so edges stay readable
 * and do not overlap when the default layout is used.
 */
function connectorPath(from: Point, to: Point): string {
  const sameRow = Math.abs(from.y - to.y) < 8;
  const sameCol = Math.abs(from.x - to.x) < 8;

  if (sameRow) {
    const y = from.y + NODE_H / 2;
    const x1 = from.x < to.x ? from.x + NODE_W : from.x;
    const x2 = from.x < to.x ? to.x : to.x + NODE_W;
    return `M ${x1} ${y} L ${x2} ${y}`;
  }

  if (sameCol || to.y > from.y) {
    // Exit bottom → enter top
    const x1 = from.x + NODE_W / 2;
    const y1 = from.y + NODE_H;
    const x2 = to.x + NODE_W / 2;
    const y2 = to.y;
    const midY = y1 + (y2 - y1) / 2;
    return `M ${x1} ${y1} L ${x1} ${midY} L ${x2} ${midY} L ${x2} ${y2}`;
  }

  // Destination above: exit top → enter bottom
  const x1 = from.x + NODE_W / 2;
  const y1 = from.y;
  const x2 = to.x + NODE_W / 2;
  const y2 = to.y + NODE_H;
  const midY = y2 + (y1 - y2) / 2;
  return `M ${x1} ${y1} L ${x1} ${midY} L ${x2} ${midY} L ${x2} ${y2}`;
}

/**
 * Small n8n-style loading spinner shown on the currently executing node.
 */
function Spinner({ className = "" }: { className?: string }) {
  return (
    <span
      className={`inline-block h-3.5 w-3.5 animate-spin rounded-full border-2 border-white/25 border-t-uni-ok ${className}`}
      aria-hidden
    />
  );
}

type Props = {
  demoCase: DemoCase;
  /** When true, advances through nodes with green borders + spinners */
  running: boolean;
  /** Fired once the animated flow finishes */
  onComplete: () => void;
};

/**
 * Interactive n8n-style canvas that visualizes the AML Hook swap lifecycle.
 * Nodes are draggable; dropping one onto another reorders the sequence.
 * Clicking "Get started" on the swap widget drives the step animation.
 */
export function FlowSimulator({ demoCase, running, onComplete }: Props) {
  const canvasRef = useRef<HTMLDivElement>(null);
  const [activeIndex, setActiveIndex] = useState(-1);
  const [done, setDone] = useState(false);
  const [order, setOrder] = useState<string[]>(() => [...DEFAULT_ORDER]);
  const [positions, setPositions] = useState<Record<string, Point>>(() =>
    initialPositions([...DEFAULT_ORDER]),
  );
  const [draggingId, setDraggingId] = useState<string | null>(null);
  const [dropTargetId, setDropTargetId] = useState<string | null>(null);
  const dragOffset = useRef<Point>({ x: 0, y: 0 });
  const onCompleteRef = useRef(onComplete);
  onCompleteRef.current = onComplete;

  /** Final result node label depends on the active wallet / risk path */
  const outcomeNode: NodeDef = useMemo(() => {
    if (demoCase.flowPath === "block") {
      return {
        id: "out",
        title: "Result · Blocked",
        subtitle: "OFAC match · revert",
        kind: "action",
      };
    }
    if (demoCase.flowPath === "surcharge") {
      return {
        id: "out",
        title: "Result · 3x fee",
        subtitle: "Structuring · surcharge",
        kind: "action",
      };
    }
    return {
      id: "out",
      title: "Result · Allowed",
      subtitle: "Standard fee",
      kind: "action",
    };
  }, [demoCase.flowPath]);

  /** Lookup table from node id → definition (including dynamic outcome) */
  const nodeById = useMemo(() => {
    const map: Record<string, NodeDef> = {};
    for (const n of BASE_NODES) map[n.id] = n;
    map[outcomeNode.id] = outcomeNode;
    return map;
  }, [outcomeNode]);

  /** Nodes in the current execution / display order */
  const nodes = useMemo(
    () => order.map((id) => nodeById[id]).filter(Boolean),
    [order, nodeById],
  );

  /** Reset layout and animation state whenever the selected case changes */
  useEffect(() => {
    const ids = [...DEFAULT_ORDER];
    setOrder(ids);
    setPositions(initialPositions(ids));
    setActiveIndex(-1);
    setDone(false);
    setDraggingId(null);
    setDropTargetId(null);
  }, [demoCase.id]);

  /**
   * Step-through animation: highlights each node with a spinner, then marks
   * completed steps green. Re-runs only when `running` or the case changes.
   */
  useEffect(() => {
    if (!running) return;

    const total = nodes.length || DEFAULT_ORDER.length;
    setActiveIndex(0);
    setDone(false);
    let i = 0;
    const timer = setInterval(() => {
      i += 1;
      if (i >= total) {
        clearInterval(timer);
        setDone(true);
        setActiveIndex(total - 1);
        onCompleteRef.current();
        return;
      }
      setActiveIndex(i);
    }, 750);

    return () => clearInterval(timer);
    // Do not restart when the user reorders nodes mid-layout
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [running, demoCase.id]);

  /**
   * Inserts `fromId` before `toId` in the flow order (used on drag-and-drop).
   */
  const reorder = (fromId: string, toId: string) => {
    if (fromId === toId) return;
    setOrder((prev) => {
      const next = prev.filter((id) => id !== fromId);
      const toIndex = next.indexOf(toId);
      if (toIndex === -1) return prev;
      next.splice(toIndex, 0, fromId);
      return next;
    });
  };

  /** Starts dragging a node; stores pointer offset relative to the node origin */
  const onPointerDown = (e: ReactPointerEvent<HTMLDivElement>, id: string) => {
    if (running) return;
    const canvas = canvasRef.current;
    if (!canvas) return;
    const rect = canvas.getBoundingClientRect();
    const pos = positions[id] ?? { x: 0, y: 0 };
    dragOffset.current = {
      x: e.clientX - rect.left - pos.x + canvas.scrollLeft,
      y: e.clientY - rect.top - pos.y + canvas.scrollTop,
    };
    setDraggingId(id);
    (e.currentTarget as HTMLElement).setPointerCapture?.(e.pointerId);
  };

  /** Moves the dragged node and highlights a drop target if hovered */
  const onPointerMove = (e: ReactPointerEvent<HTMLDivElement>) => {
    if (!draggingId || !canvasRef.current) return;
    const canvas = canvasRef.current;
    const rect = canvas.getBoundingClientRect();
    const maxX = Math.max(0, canvas.scrollWidth - NODE_W - 16);
    const maxY = Math.max(0, canvas.clientHeight - NODE_H - 16);
    const x = Math.min(
      maxX,
      Math.max(0, e.clientX - rect.left - dragOffset.current.x + canvas.scrollLeft),
    );
    const y = Math.min(
      maxY,
      Math.max(0, e.clientY - rect.top - dragOffset.current.y + canvas.scrollTop),
    );
    setPositions((prev) => ({ ...prev, [draggingId]: { x, y } }));

    const el = document.elementFromPoint(e.clientX, e.clientY);
    const target = el?.closest("[data-node-id]") as HTMLElement | null;
    const targetId = target?.dataset.nodeId ?? null;
    setDropTargetId(targetId && targetId !== draggingId ? targetId : null);
  };

  /** Ends the drag; if dropped on another node, reorders the sequence */
  const onPointerUp = () => {
    if (draggingId && dropTargetId) {
      reorder(draggingId, dropTargetId);
    }
    setDraggingId(null);
    setDropTargetId(null);
  };

  const canvasWidth = START_X + 5 * NODE_W + 4 * GAP_X + 64;
  const canvasHeight = Math.max(560, START_Y + 2 * NODE_H + GAP_Y + 96);

  const resultTone =
    demoCase.flowPath === "block"
      ? "bad"
      : demoCase.flowPath === "surcharge"
        ? "warn"
        : "ok";

  return (
    <section className="relative w-full animate-fadeUp">
      <div className="rounded-3xl border border-uni-border bg-uni-surface/80 p-4 md:p-6">
        <div
          ref={canvasRef}
          className="relative overflow-hidden rounded-2xl border border-uni-border/70 dot-grid select-none"
          style={{ height: canvasHeight }}
          onPointerMove={onPointerMove}
          onPointerUp={onPointerUp}
          onPointerLeave={onPointerUp}
        >
          <div
            className="relative mx-auto h-full"
            style={{ width: "100%", maxWidth: canvasWidth, minWidth: canvasWidth }}
          >
            <svg className="pointer-events-none absolute inset-0 h-full w-full overflow-visible">
              {order.slice(0, -1).map((id, index) => {
                const from = positions[id];
                const to = positions[order[index + 1]];
                if (!from || !to) return null;
                const active = activeIndex > index || (done && activeIndex >= index);
                return (
                  <path
                    key={`${id}-${order[index + 1]}`}
                    d={connectorPath(from, to)}
                    fill="none"
                    stroke={active ? "#40B66B" : "#3a3a3a"}
                    strokeWidth="2.5"
                    strokeLinejoin="round"
                    strokeLinecap="round"
                    strokeDasharray={active ? "0" : "6 6"}
                  />
                );
              })}
            </svg>

            {nodes.map((node, index) => {
              const pos = positions[node.id] ?? { x: 0, y: 0 };
              const isActive = running && index === activeIndex && !done;
              const completed = done || (running && activeIndex > index);
              const isDragging = draggingId === node.id;
              const isDropTarget = dropTargetId === node.id;
              const isResult = node.id === "out";

              let borderClass = "border-uni-border";
              if (isActive) {
                borderClass =
                  "border-uni-ok shadow-[0_0_0_1px_#40B66B,0_0_20px_rgba(64,182,107,0.35)]";
              } else if (done && isResult) {
                borderClass =
                  resultTone === "bad"
                    ? "border-uni-bad shadow-[0_0_16px_rgba(255,83,112,0.35)]"
                    : resultTone === "warn"
                      ? "border-uni-warn shadow-[0_0_16px_rgba(240,185,11,0.35)]"
                      : "border-uni-ok shadow-[0_0_16px_rgba(64,182,107,0.35)]";
              } else if (completed) {
                borderClass = "border-uni-ok";
              } else if (node.kind === "trigger") {
                borderClass = "border-uni-pink/40";
              } else if (node.kind === "decision") {
                borderClass = "border-uni-warn/40";
              }

              return (
                <div
                  key={node.id}
                  data-node-id={node.id}
                  onPointerDown={(e) => onPointerDown(e, node.id)}
                  className={`absolute rounded-2xl border-2 bg-uni-card/95 p-3 shadow-lg transition-all duration-300 ${borderClass} ${
                    isDragging ? "z-20 cursor-grabbing scale-[1.03] shadow-glow" : "z-10 cursor-grab"
                  } ${isDropTarget ? "ring-2 ring-uni-pink" : ""} ${
                    running ? "cursor-default" : ""
                  } ${!running && !done ? "opacity-80" : "opacity-100"}`}
                  style={{
                    width: NODE_W,
                    minHeight: NODE_H,
                    left: pos.x,
                    top: pos.y,
                    touchAction: "none",
                  }}
                >
                  <div className="mb-2 flex items-center justify-between gap-2">
                    <span className="text-[10px] font-semibold uppercase tracking-wider text-uni-muted">
                      {index + 1}. {node.kind}
                    </span>
                    <span className="flex items-center gap-1.5">
                      {isActive && <Spinner />}
                      {done && isResult && resultTone === "bad" ? (
                        <span className="flex h-3.5 w-3.5 items-center justify-center rounded-full bg-uni-bad text-[9px] font-bold text-white">
                          ✕
                        </span>
                      ) : done && isResult && resultTone === "warn" ? (
                        <span className="flex h-3.5 w-3.5 items-center justify-center rounded-full bg-uni-warn text-[9px] font-bold text-black">
                          !
                        </span>
                      ) : completed && !isActive ? (
                        <span className="flex h-3.5 w-3.5 items-center justify-center rounded-full bg-uni-ok text-[9px] font-bold text-black">
                          ✓
                        </span>
                      ) : null}
                      {!running && !done && (
                        <span className="text-[10px] text-uni-muted">⠿</span>
                      )}
                    </span>
                  </div>
                  <div className="text-sm font-semibold leading-snug">{node.title}</div>
                  <div className="mt-1 text-xs text-uni-muted">{node.subtitle}</div>
                  <div
                    className={`mt-2 font-mono text-[11px] ${
                      isActive
                        ? "text-uni-ok"
                        : completed || done
                          ? "text-white"
                          : "text-uni-muted"
                    }`}
                  >
                    {(
                      demoCase.stepTimesSec[
                        node.id as keyof typeof demoCase.stepTimesSec
                      ] ?? 0
                    ).toFixed(2)}
                    s
                  </div>
                  {node.id === "decide" && (isActive || completed || done) && (
                    <div className="mt-3 space-y-1 text-[11px]">
                      <div
                        className={
                          demoCase.flowPath === "allow" ? "text-uni-ok" : "text-uni-muted"
                        }
                      >
                        → Allow
                      </div>
                      <div
                        className={
                          demoCase.flowPath === "surcharge"
                            ? "text-uni-warn"
                            : "text-uni-muted"
                        }
                      >
                        → Surcharge 3x
                      </div>
                      <div
                        className={
                          demoCase.flowPath === "block" ? "text-uni-bad" : "text-uni-muted"
                        }
                      >
                        → Block / revert
                      </div>
                    </div>
                  )}
                  {isActive && (
                    <div className="mt-3 text-[11px] font-medium text-uni-ok">Running…</div>
                  )}
                </div>
              );
            })}
          </div>
        </div>

        <div className="mt-5 flex flex-wrap items-center justify-between gap-3 text-xs text-uni-muted">
          <span>
            Active case: <span className="text-white">{demoCase.label}</span>
          </span>
          <span>
            {running && !done && `Step ${activeIndex + 1} / ${nodes.length}`}
            {done &&
              (demoCase.flowPath === "block"
                ? "Flow complete · blocked"
                : demoCase.flowPath === "surcharge"
                  ? "Flow complete · differential fee"
                  : "Flow complete · allowed")}
            {!running && !done && 'Click "Get started" to run the flow'}
          </span>
        </div>
      </div>
    </section>
  );
}
