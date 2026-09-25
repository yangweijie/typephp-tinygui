#pragma once

#include <phpx.h>
#include <typephp_helper.h>
#include <typephp_fiber_generator.h>
#include <php_app_runtime_decl.h>

extern php::Var php_dispatch(php::Str method, php::Array params);
extern php::Var php_handleframe(php::Str raw);
extern void php_emit(php::Str s);
extern void php_main();
#include <phpx.h>
#include <typephp_helper.h>


namespace typephp_project_app {


extern THREAD_LOCAL php::Var _global_var_dispatch_store;
}  // namespace typephp_project_app
using namespace typephp_project_app;

