param(
  [switch]$PruneData
)

if ($PruneData) {
  docker compose down -v
} else {
  docker compose down
}