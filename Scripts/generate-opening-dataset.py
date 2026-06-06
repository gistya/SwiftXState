#!/usr/bin/env python3
"""Build the 5-move opening move-tree dataset from lichess-org/chess-openings TSV files."""

from __future__ import annotations

import csv
import io
import json
import sys
import urllib.request
from collections import defaultdict
from dataclasses import dataclass
from pathlib import Path

import chess
import chess.pgn

MAX_PLIES = 10
TSV_URL = "https://raw.githubusercontent.com/lichess-org/chess-openings/master/{volume}.tsv"
VOLUMES = ("a", "b", "c", "d", "e")
ROOT_ID = "s0"


def normalize_fen(board: chess.Board) -> str:
    """Semantic FEN key: placement, side, castling, en-passant (no clocks)."""
    full = board.fen()
    parts = full.split()
    return " ".join(parts[:4])


def split_name(name: str) -> tuple[str, str]:
    if ":" in name:
        opening, variation = name.split(":", 1)
        return opening.strip(), variation.strip()
    return name.strip(), ""


def event_type_for_san(san: str) -> str:
    return f"SAN.{san}"


@dataclass
class LabelEntry:
    eco: str
    name: str
    variation: str
    depth: int
    state_id: str


def main() -> int:
    repo_root = Path(__file__).resolve().parents[1]
    cache_dir = repo_root / "Scripts" / ".opening-tsv-cache"
    cache_dir.mkdir(parents=True, exist_ok=True)
    out_path = repo_root / "Examples" / "SwiftXChess" / "Data" / "openings-5move.json"

    transitions: dict[str, dict[str, str]] = {ROOT_ID: {}}
    edge_index: dict[tuple[str, str], str] = {}
    next_id = 1

    def ensure_node(node_id: str) -> None:
        transitions.setdefault(node_id, {})

    def child_for(parent_id: str, san: str) -> str:
        nonlocal next_id
        key = (parent_id, san)
        if key in edge_index:
            return edge_index[key]
        child_id = f"s{next_id}"
        next_id += 1
        edge_index[key] = child_id
        ensure_node(parent_id)
        ensure_node(child_id)
        transitions[parent_id][san] = child_id
        return child_id

    fen_labels: dict[str, list[LabelEntry]] = defaultdict(list)
    fen_states: dict[str, set[str]] = defaultdict(set)

    rows_loaded = 0
    for volume in VOLUMES:
        tsv_path = cache_dir / f"{volume}.tsv"
        if not tsv_path.exists():
            url = TSV_URL.format(volume=volume)
            print(f"Downloading {url} …")
            urllib.request.urlretrieve(url, tsv_path)

        with tsv_path.open(newline="", encoding="utf-8") as handle:
            reader = csv.DictReader(handle, delimiter="\t")
            for row in reader:
                eco = row["eco"].strip()
                name = row["name"].strip()
                pgn = row["pgn"].strip()
                if not pgn:
                    continue

                game = chess.pgn.read_game(io.StringIO(pgn))
                if game is None:
                    continue

                board = game.board()
                node_id = ROOT_ID
                depth = 0
                opening, variation = split_name(name)

                fen_key = normalize_fen(board)
                fen_states[fen_key].add(node_id)
                fen_labels[fen_key].append(
                    LabelEntry(eco, opening, variation, depth, node_id)
                )

                for move in game.mainline_moves():
                    if depth >= MAX_PLIES:
                        break
                    san = board.san(move)
                    board.push(move)
                    depth += 1
                    node_id = child_for(node_id, san)
                    fen_key = normalize_fen(board)
                    fen_states[fen_key].add(node_id)
                    fen_labels[fen_key].append(
                        LabelEntry(eco, opening, variation, depth, node_id)
                    )

                rows_loaded += 1

    nodes: dict[str, dict[str, str]] = {}
    for node_id, outs in transitions.items():
        nodes[node_id] = {
            event_type_for_san(san): target
            for san, target in sorted(outs.items())
        }

    labels_json: dict[str, list[dict]] = {}
    for fen_key, entries in fen_labels.items():
        seen: set[tuple] = set()
        unique: list[dict] = []
        for entry in entries:
            key = (entry.eco, entry.name, entry.variation, entry.depth, entry.state_id)
            if key in seen:
                continue
            seen.add(key)
            unique.append(
                {
                    "eco": entry.eco,
                    "name": entry.name,
                    "variation": entry.variation,
                    "depth": entry.depth,
                    "stateId": entry.state_id,
                }
            )
        labels_json[fen_key] = unique

    payload = {
        "version": 1,
        "maxPlies": MAX_PLIES,
        "rootId": ROOT_ID,
        "nodes": nodes,
        "fenLabels": labels_json,
        "equivalence": {fen: sorted(state_ids) for fen, state_ids in fen_states.items()},
        "stats": {
            "tsvRows": rows_loaded,
            "nodeCount": len(nodes),
            "fenCount": len(labels_json),
        },
    }

    out_path.parent.mkdir(parents=True, exist_ok=True)
    with out_path.open("w", encoding="utf-8") as handle:
        json.dump(payload, handle, separators=(",", ":"), sort_keys=True)

    print(
        f"Wrote {out_path} — {payload['stats']['nodeCount']} nodes, "
        f"{payload['stats']['fenCount']} FEN keys, {payload['stats']['tsvRows']} TSV rows"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())