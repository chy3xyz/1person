"use client"

import { cn } from "@1person/ui/lib/utils";

export interface TreeNode {
  id: string;
  name: string;
  role: string;
  avatar?: string;
  children?: TreeNode[];
}

export interface DownlineTreeProps {
  data: TreeNode[];
  maxDepth?: number;
  className?: string;
  onNodeClick?: (nodeId: string) => void;
}

const ROLE_BADGES: Record<string, string> = {
  super_admin: "bg-red-100 text-red-700 dark:bg-red-900 dark:text-red-300",
  region_admin: "bg-orange-100 text-orange-700 dark:bg-orange-900 dark:text-orange-300",
  area_admin: "bg-amber-100 text-amber-700 dark:bg-amber-900 dark:text-amber-300",
  community_leader: "bg-blue-100 text-blue-700 dark:bg-blue-900 dark:text-blue-300",
  ambassador: "bg-green-100 text-green-700 dark:bg-green-900 dark:text-green-300",
  member: "bg-gray-100 text-gray-600 dark:bg-gray-800 dark:text-gray-400",
};

function TreeNodeRow({
  node,
  depth,
  maxDepth,
  isLast,
  onNodeClick,
}: {
  node: TreeNode;
  depth: number;
  maxDepth: number;
  isLast: boolean;
  onNodeClick?: (id: string) => void;
}) {
  const badge = ROLE_BADGES[node.role] || "bg-gray-100 text-gray-600";

  return (
    <div className={cn("flex flex-col", depth > 0 && "ml-6")}>
      <div className="flex items-center gap-2 py-1.5">
        {/* Tree lines */}
        {depth > 0 && (
          <div className="flex items-center">
            <div className={cn("border-l-2 border-b-2 border-gray-300 dark:border-gray-600 h-4 w-4", isLast && "rounded-bl-lg")} />
          </div>
        )}
        {/* Node content */}
        <button
          type="button"
          onClick={() => onNodeClick?.(node.id)}
          className={cn(
            "flex items-center gap-2 px-2 py-1 rounded-md hover:bg-muted transition-colors text-left",
          )}
        >
          {node.avatar ? (
            <img src={node.avatar} alt={node.name} className="h-6 w-6 rounded-full" />
          ) : (
            <div className="h-6 w-6 rounded-full bg-muted flex items-center justify-center text-xs font-medium">
              {node.name.charAt(0)}
            </div>
          )}
          <span className="text-sm font-medium">{node.name}</span>
          <span className={cn("text-xs px-1.5 py-0.5 rounded-full font-medium", badge)}>
            {node.role}
          </span>
        </button>
      </div>
      {/* Children */}
      {node.children && depth < maxDepth && (
        <div className="border-l-2 border-gray-300 dark:border-gray-600">
          {node.children.map((child, i) => (
            <TreeNodeRow
              key={child.id}
              node={child}
              depth={depth + 1}
              maxDepth={maxDepth}
              isLast={i === node.children!.length - 1}
              onNodeClick={onNodeClick}
            />
          ))}
        </div>
      )}
    </div>
  );
}

export function DownlineTree({
  data,
  maxDepth = 5,
  className,
  onNodeClick,
}: DownlineTreeProps) {
  if (!data.length) {
    return (
      <div className="p-4 text-center text-sm text-muted-foreground">
        No members in downline
      </div>
    );
  }

  return (
    <div className={cn("p-2", className)}>
      {data.map((node, i) => (
        <TreeNodeRow
          key={node.id}
          node={node}
          depth={0}
          maxDepth={maxDepth}
          isLast={i === data.length - 1}
          onNodeClick={onNodeClick}
        />
      ))}
    </div>
  );
}
