#!/bin/bash
# Generate the inline-switch block for router.zig.
set -euo pipefail
cd /Users/n0x/w4_proj/dev_machine/1person/zserver
MODULES=(
  config auth realtime attachment user workspace invitation lark token
  billing assignee_frequency issue task label project squad autopilot pin
  comment agent agent_template skill dashboard runtime chat inbox
  notification_preference daemon webhook contact health_realtime
)
echo "    inline for (modules) |name| {"
echo "        const mod = switch (name) {"
for m in "${MODULES[@]}"; do
  echo "            \"$m\" => @import(\"modules/$m/routes.zig\"),"
done
echo "            else => @compileError(\"unknown module: \" ++ name),"
echo "        };"
echo "        try mod.register(app);"
echo "    }"
