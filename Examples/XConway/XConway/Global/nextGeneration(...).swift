public nonisolated func nextGeneration(cells: [Bool], width: Int, height: Int, rules: LifeRules) -> [Bool] {
    var next = Array(repeating: false, count: width * height)
    let dirs = [(-1,-1), (0,-1), (1,-1), (-1,0), (1,0), (-1,1), (0,1), (1,1)]

    for y in 0..<height {
        for x in 0..<width {
            let idx = y * width + x
            let alive = cells[idx]
            var neighbors = 0
            for (dx, dy) in dirs {
                let nx = (x + dx + width) % width   // toroidal wrap (classic for GoL demos)
                let ny = (y + dy + height) % height
                if cells[ny * width + nx] { neighbors += 1 }
            }
            if alive {
                next[idx] = rules.survive.contains(neighbors)
            } else {
                next[idx] = rules.birth.contains(neighbors)
            }
        }
    }
    return next
}
