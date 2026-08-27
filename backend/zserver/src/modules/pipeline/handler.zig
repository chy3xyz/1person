//! Pipeline module — HTTP handler passthroughs.

const zfinal = @import("zfinal");
const service = @import("service.zig");

pub fn listPipelineConfigs(ctx: *zfinal.Context) !void {
    try service.listPipelineConfigs(ctx);
}
pub fn createPipelineConfig(ctx: *zfinal.Context) !void {
    try service.createPipelineConfig(ctx);
}
pub fn getPipelineConfig(ctx: *zfinal.Context) !void {
    try service.getPipelineConfig(ctx);
}
pub fn updatePipelineConfig(ctx: *zfinal.Context) !void {
    try service.updatePipelineConfig(ctx);
}
pub fn deletePipelineConfig(ctx: *zfinal.Context) !void {
    try service.deletePipelineConfig(ctx);
}
pub fn startPipeline(ctx: *zfinal.Context) !void {
    try service.startPipeline(ctx);
}
pub fn listPipelineRuns(ctx: *zfinal.Context) !void {
    try service.listPipelineRuns(ctx);
}
pub fn getPipelineRun(ctx: *zfinal.Context) !void {
    try service.getPipelineRun(ctx);
}
pub fn completePhase(ctx: *zfinal.Context) !void {
    try service.completePhase(ctx);
}
