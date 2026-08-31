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
    title: "Swap",
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
    subtitle: "Sanctions / exploit screen",
    kind: "process",
  },
  {
    id: "l2",
    title: "Layer 2 · Keeper score",
    subtitle: "N-hop oracle",
    kind: "process",
  },
  {
    id: "decide",
    title: "Layer 3 · Decision",
    subtitle: "Allow / Fee override / Revert",
    kind: "decision",
  },
];

const NODE_W = 156;
/** Base card height (decision card is taller: reserved space for branches) */
const NODE_H = 92;
const DECIDE_H = 138;
const GAP_X = 42;
const GAP_Y = 48;
const START_X = 20;
const START_Y = 20;
const PAD_R = 20;
const PAD_B = 20;

/**
 * Snake grid like the n8n reference:
 * Row 0 → 1 2 3 4
 * Row 1 → 5 6 7  (wrap under, left-to-right: lines never cross)
 */
const DEFAULT_SLOTS: Record<string, { col: number; row: number }> = {
  sign: { col: 0, row: 0 },
  unlock: { col: 1, row: 0 },
  before: { col: 2, row: 0 },
  l1: { col: 3, row: 0 },
  l2: { col: 0, row: 1 },
  decide: { col: 1, row: 1 },
  out: { col: 2, row: 1 },
};

/**
 * Returns the rendered height for a node (decision reserves branch list space).
 */
function nodeHeight(id: string): number {
  return id === "decide" ? DECIDE_H : NODE_H;
}

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
 * Orthogonal (Manhattan) connector that prefers side/bottom ports so edges
 * stay in gutters and do not cross nodes on the default snake layout.
 */
function connectorPath(
  fromId: string,
  toId: string,
  from: Point,
  to: Point,
): string {
  const fromH = nodeHeight(fromId);
  const toH = nodeHeight(toId);
  const fromMidY = from.y + fromH / 2;
  const toMidY = to.y + toH / 2;
  const sameRow = Math.abs(from.y - to.y) < 8;

  // Same row, left → right: right-center → left-center
  if (sameRow && to.x > from.x) {
    return `M ${from.x + NODE_W} ${fromMidY} L ${to.x} ${toMidY}`;
  }

  // Same row, right → left (rare after reorder)
  if (sameRow && to.x < from.x) {
    return `M ${from.x} ${fromMidY} L ${to.x + NODE_W} ${toMidY}`;
  }

  // Snake wrap: top-row node down into bottom-row node to the left
  // Exit bottom → gutter → left → enter left-center (matches reference photo)
  if (to.y > from.y && to.x < from.x) {
    const exitX = from.x + NODE_W / 2;
    const exitY = from.y + fromH;
    const midY = from.y + fromH + (to.y - (from.y + fromH)) / 2;
    const enterX = to.x;
    const enterY = toMidY;
    return `M ${exitX} ${exitY} L ${exitX} ${midY} L ${enterX} ${midY} L ${enterX} ${enterY}`;
  }

  // Downward, destination under or to the right: bottom → gutter → top
  if (to.y > from.y) {
    const exitX = from.x + NODE_W / 2;
    const exitY = from.y + fromH;
    const enterX = to.x + NODE_W / 2;
    const enterY = to.y;
    const midY = exitY + (enterY - exitY) / 2;
    return `M ${exitX} ${exitY} L ${exitX} ${midY} L ${enterX} ${midY} L ${enterX} ${enterY}`;
  }

  // Upward: top → gutter → bottom
  const exitX = from.x + NODE_W / 2;
  const exitY = from.y;
  const enterX = to.x + NODE_W / 2;
  const enterY = to.y + toH;
  const midY = enterY + (exitY - enterY) / 2;
  return `M ${exitX} ${exitY} L ${exitX} ${midY} L ${enterX} ${midY} L ${enterX} ${enterY}`;
}

/**
 * Progress wheel that fills over this node's `stepTimesSec`.
 */
function StepWheel({ progress }: { progress: number }) {
  const p = Math.min(1, Math.max(0, progress));
  const r = 5.5;
  const c = 2 * Math.PI * r;
  return (
    <svg width="16" height="16" viewBox="0 0 16 16" aria-hidden className="shrink-0">
      <circle
        cx="8"
        cy="8"
        r={r}
        fill="none"
        stroke="rgb(var(--ink) / 0.14)"
        strokeWidth="2"
      />
      <circle
        cx="8"
        cy="8"
        r={r}
        fill="none"
        stroke="#40B66B"
        strokeWidth="2"
        strokeLinecap="round"
        strokeDasharray={c}
        strokeDashoffset={c * (1 - p)}
        transform="rotate(-90 8 8)"
      />
    </svg>
  );
}

type StepId = keyof DemoCase["stepTimesSec"];

/**
 * Dwell time for a flow node: matches the layer's recorded execution time.
 */
function stepDurationMs(times: DemoCase["stepTimesSec"], id: string): number {
  const sec = times[id as StepId] ?? 0.2;
  return Math.max(1, Math.round(sec * 1000));
}

type Props = {
  demoCase: DemoCase;
  /** When true, advances through nodes with filling wheels */
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
  const [elapsedMs, setElapsedMs] = useState(0);
  const dragOffset = useRef<Point>({ x: 0, y: 0 });
  const onCompleteRef = useRef(onComplete);
  const orderRef = useRef(order);
  onCompleteRef.current = onComplete;
  orderRef.current = order;

  /** Final result node label depends on the active wallet / risk path */
  const outcomeNode: NodeDef = useMemo(() => {
    if (demoCase.flowPath === "block") {
      return {
        id: "out",
        title: "Result · Blocked",
        subtitle: "Exploit · REVERT",
        kind: "action",
      };
    }
    if (demoCase.flowPath === "fee_override") {
      return {
        id: "out",
        title: "Result · Fee override",
        subtitle: "N-hop · FeeEscrow",
        kind: "action",
      };
    }
    return {
      id: "out",
      title: "Result · Allowed",
      subtitle: "Standard fee 0.30%",
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
    setElapsedMs(0);
    setDraggingId(null);
    setDropTargetId(null);
  }, [demoCase.id]);

  /**
   * Step-through animation: each node stays active for that layer's real
   * execution time (`stepTimesSec`) while its wheel fills. Settlement
   * runs when the graph completes; the user clicks to open Fees.
   */
  useEffect(() => {
    if (!running) return;

    const ids = orderRef.current;
    const total = ids.length || DEFAULT_ORDER.length;
    const times = demoCase.stepTimesSec;
    setActiveIndex(0);
    setDone(false);
    setElapsedMs(0);

    let i = 0;
    let cancelled = false;
    let timeout: ReturnType<typeof setTimeout> | undefined;
    let raf = 0;
    let stepStarted = performance.now();

    const tick = () => {
      if (cancelled) return;
      setElapsedMs(performance.now() - stepStarted);
      raf = requestAnimationFrame(tick);
    };
    raf = requestAnimationFrame(tick);

    const arm = () => {
      const id = ids[i] ?? DEFAULT_ORDER[i];
      timeout = setTimeout(() => {
        if (cancelled) return;
        i += 1;
        if (i >= total) {
          setDone(true);
          setActiveIndex(total - 1);
          setElapsedMs(0);
          onCompleteRef.current();
          return;
        }
        stepStarted = performance.now();
        setElapsedMs(0);
        setActiveIndex(i);
        arm();
      }, stepDurationMs(times, id));
    };
    arm();

    return () => {
      cancelled = true;
      if (timeout) clearTimeout(timeout);
      cancelAnimationFrame(raf);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [running, demoCase.id, demoCase.stepTimesSec]);

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
    const maxY = Math.max(0, canvas.scrollHeight - NODE_H - 16);
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

  // 4 columns × 2 rows: fits viewport; out node (col 2) always on-screen
  const canvasWidth = START_X + 4 * NODE_W + 3 * GAP_X + PAD_R;
  const canvasHeight = START_Y + NODE_H + GAP_Y + DECIDE_H + PAD_B;

  const resultTone =
    demoCase.flowPath === "block"
      ? "bad"
      : demoCase.flowPath === "fee_override"
        ? "warn"
        : "ok";

  return (
    <section className="relative w-full">
      <div className="surface radius-e border-l hair p-3 md:translate-x-5 md:p-5">
        <div
          ref={canvasRef}
          className="relative overflow-x-auto overflow-y-hidden bg-transparent dot-grid select-none"
          style={{ minHeight: canvasHeight }}
          onPointerMove={onPointerMove}
          onPointerUp={onPointerUp}
          onPointerLeave={onPointerUp}
        >
          <div
            className="relative mx-auto"
            style={{ width: canvasWidth, height: canvasHeight }}
          >
            <svg
              className="pointer-events-none absolute inset-0 overflow-visible"
              width={canvasWidth}
              height={canvasHeight}
              viewBox={`0 0 ${canvasWidth} ${canvasHeight}`}
            >
              {order.slice(0, -1).map((id, index) => {
                const nextId = order[index + 1];
                const from = positions[id];
                const to = positions[nextId];
                if (!from || !to) return null;
                const active = activeIndex > index || (done && activeIndex >= index);
                return (
                  <path
                    key={`${id}-${nextId}`}
                    d={connectorPath(id, nextId, from, to)}
                    fill="none"
                    stroke={active ? "rgb(var(--ink))" : "rgb(var(--border))"}
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
              const targetSec =
                demoCase.stepTimesSec[node.id as StepId] ?? 0;
              const targetMs = Math.max(1, Math.round(targetSec * 1000));
              const wheelProgress = isActive ? elapsedMs / targetMs : 0;
              const isDragging = draggingId === node.id;
              const isDropTarget = dropTargetId === node.id;
              const isResult = node.id === "out";
              const height = nodeHeight(node.id);

              let borderClass = "border-l hair";
              let radiusClass = "radius-node-action";
              if (node.kind === "trigger") radiusClass = "radius-node-trigger";
              if (node.kind === "decision") radiusClass = "radius-node-decision";
              if (isResult) radiusClass = "radius-node-result";

              if (isActive) {
                borderClass = "border-l-[1.5px] border-uni-ok";
              } else if (done && isResult) {
                borderClass =
                  resultTone === "bad"
                    ? "border-l-[1.5px] border-uni-bad"
                    : resultTone === "warn"
                      ? "border-l-[1.5px] border-uni-warn"
                      : "border-l-[1.5px] border-uni-ok";
              } else if (completed) {
                borderClass = "border-l border-uni-ok/45";
              } else if (node.kind === "trigger") {
                borderClass = "border-l hair";
              } else if (node.kind === "decision") {
                borderClass = "border-l border-uni-warn/25";
              }

              return (
                <div
                  key={node.id}
                  data-node-id={node.id}
                  onPointerDown={(e) => onPointerDown(e, node.id)}
                  className={`absolute surface p-2 transition-[border-color,opacity,transform] duration-300 ${radiusClass} ${borderClass} ${
                    isDragging ? "z-20 cursor-grabbing scale-[1.03]" : "z-10 cursor-grab"
                  } ${isDropTarget ? "border-l-[1.5px] border-uni-pink/50" : ""} ${
                    running ? "cursor-default" : ""
                  } ${!running && !done ? "opacity-80" : "opacity-100"}`}
                  style={{
                    width: NODE_W,
                    height,
                    left: pos.x,
                    top: pos.y,
                    touchAction: "none",
                  }}
                >
                  <div className="mb-1 flex items-center justify-between gap-1">
                    <span className="text-[9px] font-semibold uppercase tracking-wider text-uni-muted">
                      {index + 1}. {node.kind}
                    </span>
                    <span className="flex items-center gap-1">
                      {isActive && <StepWheel progress={wheelProgress} />}
                      {done && isResult && resultTone === "bad" ? (
                        <span className="flex h-3 w-3 items-center justify-center rounded-full bg-uni-bad text-[8px] font-bold text-white">
                          ✕
                        </span>
                      ) : done && isResult && resultTone === "warn" ? (
                        <span className="flex h-3 w-3 items-center justify-center rounded-full bg-uni-warn text-[8px] font-bold text-black">
                          !
                        </span>
                      ) : completed && !isActive ? (
                        <span className="flex h-3 w-3 items-center justify-center rounded-full bg-uni-ok text-[8px] font-bold text-black">
                          ✓
                        </span>
                      ) : null}
                      {!running && !done && (
                        <span className="text-[9px] text-uni-muted">⠿</span>
                      )}
                    </span>
                  </div>
                  <div className="font-serif text-xs leading-snug">{node.title}</div>
                  <div className="mt-0.5 text-[10px] leading-tight text-uni-muted">
                    {node.subtitle}
                  </div>
                  <div
                    className={`mt-1 font-mono text-[10px] ${
                      isActive
                        ? "text-uni-ok"
                        : completed || done
                          ? "text-uni-pink"
                          : "text-uni-muted"
                    }`}
                  >
                    {(() => {
                      if (isActive && !done) {
                        return Math.min(targetSec, elapsedMs / 1000).toFixed(2);
                      }
                      return targetSec.toFixed(2);
                    })()}
                    s
                  </div>
                  {node.id === "decide" && (
                    <div className="mt-1.5 space-y-0.5 text-[10px] leading-tight">
                      <div
                        className={
                          (isActive || completed || done) &&
                          demoCase.flowPath === "allow"
                            ? "text-uni-ok"
                            : "text-uni-muted"
                        }
                      >
                        → Allow
                      </div>
                      <div
                        className={
                          (isActive || completed || done) &&
                          demoCase.flowPath === "fee_override"
                            ? "text-uni-warn"
                            : "text-uni-muted"
                        }
                      >
                        → Fee override
                      </div>
                      <div
                        className={
                          (isActive || completed || done) &&
                          demoCase.flowPath === "block"
                            ? "text-uni-bad"
                            : "text-uni-muted"
                        }
                      >
                        → Block / revert
                      </div>
                    </div>
                  )}
                  {isActive && (
                    <div className="mt-1 text-[10px] font-medium text-uni-ok">
                      Running…
                    </div>
                  )}
                </div>
              );
            })}
          </div>
        </div>
      </div>
    </section>
  );
}
