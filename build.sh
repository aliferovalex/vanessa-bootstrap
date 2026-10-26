#!/bin/bash
if [ -f src/cf/.project ]; then
  echo "EDT sources require EDT-to-XML conversion. See doc/EDT-INITIALIZATION.md." >&2
  exit 2
fi

# формирование файла конфигурации. для включения раскомментируйте код ниже
vrunner compile --src src/cf --out build/1cv8.cf "$@"

# обновление конфигурации основной разработческой ИБ из хранилища. для включения раскомментируйте код ниже
# vrunner loadrepo "$@"
# vrunner updatedb "$@"

# собрать внешние обработчики и отчеты в каталоге build
# vrunner compileepf src/epf/МояВнешняяОбработка build "$@"
# vrunner compileepf src/erf/МойВнешнийОтчет build "$@"

# собрать расширения конфигурации внутри ИБ
# vrunner compileext src/cfe/МоеРасширение МоеРасширение "$@"
