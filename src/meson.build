appinstaller_sources = [
  'main.vala',
  'application.vala',
  'window.vala',
]

appinstaller_deps = [
  config_dep,
  dependency('gtk4'),
  dependency('gdk-pixbuf-2.0'),
  dependency('libadwaita-1', version: '>= 1.4'),
  meson.get_compiler('vala').find_library('posix'),
]

appinstaller_sources += gnome.compile_resources('appinstaller-resources',
  'appinstaller.gresource.xml',
  c_name: 'appinstaller'
)

executable('appinstaller', appinstaller_sources,
  dependencies: appinstaller_deps,
  include_directories: config_inc,
       install: true,
)
