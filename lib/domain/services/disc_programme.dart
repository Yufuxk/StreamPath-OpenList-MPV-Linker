enum DiscType { bluray, dvd }

bool isDvdProgramme(String id) =>
    RegExp(r'^dvd-title-(0[1-9]|[1-9]\d)$').hasMatch(id);

bool isDiscProgramme(String id) =>
    RegExp(r'^\d{5}$').hasMatch(id) || isDvdProgramme(id);

String discProgrammeLabel(String id) =>
    isDvdProgramme(id) ? 'Title ${id.substring(10)}' : '$id.mpls';

String discProgrammeResumeId(String id) =>
    isDvdProgramme(id) ? 'dvd-title://${id.substring(10)}' : 'bd://mpls/$id';
