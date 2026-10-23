import WinnowProofs.Generated

/-- `lake exe emit <directory>` writes every generated Swift file there. -/
def main (args : List String) : IO UInt32 := do
  match args with
  | [dir] =>
    IO.FS.createDirAll dir
    for file in Winnow.files do
      IO.FS.writeFile (System.FilePath.mk dir / file.path) file.render
    pure 0
  | _ =>
    IO.eprintln "usage: lake exe emit <output directory>"
    pure 2
