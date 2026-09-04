`adders.v` and `mpmac.v` are vendored verbatim from
https://github.com/devesh-b/multiprecision-datapath, where they are verified
(1,467,310 self-checked vectors, and `eqy` proving the two architectures
equivalent). They are copied rather than submoduled so a fresh clone of this
repository runs without a second checkout.

Nothing in this repository modifies them. The protected datapath reuses
`mp_frontend` and `seg_add48` from `mpmac.v` and adds its own accumulate path,
so `mpmac_unprot` here is proved equivalent to `mpmac_shared` there
(`formal/equiv_unprot.eqy`) rather than assumed to match.
