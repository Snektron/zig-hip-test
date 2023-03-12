unsigned int workitem_x() {
    return __builtin_amdgcn_workitem_id_x();
}

unsigned int workitem_y() {
    return __builtin_amdgcn_workitem_id_y();
}

unsigned int workitem_z() {
    return __builtin_amdgcn_workitem_id_z();
}

unsigned int workgroup_x() {
    return __builtin_amdgcn_workgroup_id_x();
}

unsigned int workgroup_y() {
    return __builtin_amdgcn_workgroup_id_y();
}

unsigned int workgroup_z() {
    return __builtin_amdgcn_workgroup_id_z();
}
