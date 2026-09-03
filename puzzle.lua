local Chess = require("chess/src/chess")

local Puzzle = {}

-- Create a new puzzle state
-- @param fen: The FEN string of the position.
-- @param uci_moves: An array (or space-separated string) of UCI moves.
-- @param first_move_is_opponent: Boolean. If true, the first move should be auto-played.
function Puzzle.new(fen, uci_moves, first_move_is_opponent)
    local p = {
        initial_fen = fen,
        moves = type(uci_moves) == "string" and {} or uci_moves,
        current_step = 1,
        first_move_is_opponent = first_move_is_opponent or false,
        completed = false,
    }
    
    if type(uci_moves) == "string" then
        for move in uci_moves:gmatch("%S+") do
            table.insert(p.moves, move)
        end
    end
    
    return setmetatable(p, { __index = Puzzle })
end

function Puzzle:getNextExpectedMove()
    if self.current_step > #self.moves then return nil end
    return self.moves[self.current_step]
end

function Puzzle:advance()
    self.current_step = self.current_step + 1
end

function Puzzle:isComplete()
    return self.current_step > #self.moves
end

return Puzzle
