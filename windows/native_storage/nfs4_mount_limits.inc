static void
sp_nfs4_mount_limits_cb(struct rpc_context *rpc, int status, void *command_data,
                        void *private_data)
{
        struct nfs4_cb_data *data = private_data;
        struct nfs_context *nfs = data->nfs;
        COMPOUND4res *res = command_data;
        GETATTR4resok *attrs;
        ZDR zdr;
        uint64_t readmax = nfs->nfsi->readmax, writemax = nfs->nfsi->writemax;
        const uint32_t mask = (1U << FATTR4_MAXREAD) | (1U << FATTR4_MAXWRITE);
        uint32_t returned, word;
        int i, valid;

        if (check_nfs4_error(nfs, status, data, res, "GETATTR transfer limits")) {
                return;
        }
        if ((i = nfs4_find_op(nfs, data, res, OP_GETATTR, "GETATTR")) < 0) {
                return;
        }
        attrs = &res->resarray.resarray_val[i].nfs_resop4_u.opgetattr.GETATTR4res_u.resok4;
        returned = attrs->obj_attributes.attrmask.bitmap4_len ?
                   attrs->obj_attributes.attrmask.bitmap4_val[0] : 0;
        valid = !(returned & ~mask);
        for (word = 1; word < attrs->obj_attributes.attrmask.bitmap4_len; word++) {
                valid = valid && !attrs->obj_attributes.attrmask.bitmap4_val[word];
        }
        if (!valid || attrs->obj_attributes.attr_vals.attrlist4_len !=
            8U * (!!(returned & (1U << FATTR4_MAXREAD)) +
                  !!(returned & (1U << FATTR4_MAXWRITE)))) {
                nfs_set_error(nfs, "Invalid NFSv4 transfer limit attributes");
                data->cb(-EINVAL, nfs, nfs_get_error(nfs), data->private_data);
                free_nfs4_cb_data(data);
                return;
        }
        zdrmem_create(&zdr, attrs->obj_attributes.attr_vals.attrlist4_val,
                      attrs->obj_attributes.attr_vals.attrlist4_len, ZDR_DECODE);
        i = (!(returned & (1U << FATTR4_MAXREAD)) || zdr_uint64_t(&zdr, &readmax)) &&
            (!(returned & (1U << FATTR4_MAXWRITE)) || zdr_uint64_t(&zdr, &writemax));
        zdr_destroy(&zdr);
        if (!i || !readmax || !writemax) {
                nfs_set_error(nfs, "Invalid NFSv4 transfer limits");
                data->cb(-EINVAL, nfs, nfs_get_error(nfs), data->private_data);
                free_nfs4_cb_data(data);
                return;
        }

        // 保留客户端配置上限，同时服从服务端允许的块大小。
        nfs->nfsi->readmax = MIN(nfs->nfsi->readmax, readmax);
        nfs->nfsi->writemax = MIN(nfs->nfsi->writemax, writemax);
        rpc_set_resiliency(rpc, nfs->nfsi->auto_reconnect,
                           nfs->nfsi->timeout, nfs->nfsi->retrans);
        data->cb(0, nfs, NULL, data->private_data);
        free_nfs4_cb_data(data);
}

static int
sp_nfs4_query_mount_limits(struct nfs_context *nfs, struct nfs4_cb_data *data)
{
        COMPOUND4args args;
        nfs_argop4 op[2];
        struct nfsfh root;
        uint32_t mask = (1U << FATTR4_MAXREAD) | (1U << FATTR4_MAXWRITE);
        int i;

        memset(&root, 0, sizeof(root));
        root.fh = nfs->nfsi->rootfh;
        memset(op, 0, sizeof(op));
        i = nfs4_op_putfh(nfs, &op[0], &root);
        i += nfs4_op_getattr(nfs, &op[i], &mask, 1);
        memset(&args, 0, sizeof(args));
        args.argarray.argarray_len = i;
        args.argarray.argarray_val = op;
        return rpc_nfs4_compound_task(nfs->rpc, sp_nfs4_mount_limits_cb,
                                     &args, data) ? 0 : -ENOMEM;
}

