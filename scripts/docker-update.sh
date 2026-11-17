for stack in services sites; do
  docker stack services "$stack" --format '{{.Name}}' | xargs -I{} docker service update --force --detach=true {}
done
