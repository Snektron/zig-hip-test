unsigned int workItemX() {
    return __builtin_amdgcn_workitem_id_x();
}

unsigned int workGroupX() {
    return __builtin_amdgcn_workgroup_id_x();
}

unsigned int workDimX() {
    return __builtin_amdgcn_workgroup_size_x();
}

void syncThreads() {
    __builtin_amdgcn_s_barrier();
}
