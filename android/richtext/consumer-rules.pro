# RichText ships no reflection, no dynamic class loading, and no resources that ProGuard/R8 would strip by
# mistake, so consumers need no extra keep rules. Kept as an explicit (empty) file so the module's
# consumerProguardFiles wiring is present and future keep rules have a home.
