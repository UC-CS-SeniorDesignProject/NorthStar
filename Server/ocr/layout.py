from typing import List, Tuple


def _x_overlap_ratio(block_bbox: List[float], col_x1: float, col_x2: float) -> float:
    bx1, _, bx2, _ = block_bbox
    block_w = bx2 - bx1
    if block_w <= 0:
        return 0.0
    overlap = max(0.0, min(bx2, col_x2) - max(bx1, col_x1))
    return overlap / block_w


def group_into_regions(
    blocks: list,
    overlap_threshold: float = 0.4,
) -> Tuple[list, str]:
    if not blocks:
        return [], ""
    columns: List[dict] = []

    for i, block in enumerate(blocks):
        bx1, _, bx2, _ = block.bbox_xyxy

        best_col = -1
        best_overlap = 0.0

        for ci, col in enumerate(columns):
            ratio = _x_overlap_ratio(block.bbox_xyxy, col["x1"], col["x2"])
            if ratio > best_overlap:
                best_overlap = ratio
                best_col = ci

        if best_col >= 0 and best_overlap >= overlap_threshold:
            col = columns[best_col]
            col["members"].append(i)
            col["x1"] = min(col["x1"], bx1)
            col["x2"] = max(col["x2"], bx2)
        else:
            columns.append({"x1": bx1, "x2": bx2, "members": [i]})

    columns.sort(key=lambda c: c["x1"])

    ordered_blocks = []
    region_texts: List[List[str]] = []

    for region_idx, col in enumerate(columns):
        member_blocks = [blocks[i] for i in col["members"]]
        member_blocks.sort(key=lambda b: b.bbox_xyxy[1])

        texts = []
        for b in member_blocks:
            b.region = region_idx
            ordered_blocks.append(b)
            if b.text.strip():
                texts.append(b.text)
        if texts:
            region_texts.append(texts)
    full_text = "\n\n".join("\n".join(t) for t in region_texts)

    return ordered_blocks, full_text
