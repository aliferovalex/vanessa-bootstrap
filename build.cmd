@if exist "%~dp0src\cf\.project" (
  @echo EDT sources require EDT-to-XML conversion before vrunner. See doc/EDT-INITIALIZATION.md. 1>&2
  @exit /b 2
)
@chcp 65001

@rem формирование файла конфигурации. для включения раскомментируйте код ниже
call vrunner compile --src src/cf --out build/1cv8.cf %*

@rem обновление конфигурации основной разработческой ИБ из хранилища. для включения раскомментируйте код ниже
@rem call vrunner loadrepo %*
@rem call vrunner updatedb %*

@rem собрать внешние обработчики и отчеты в каталоге build
@rem call vrunner compileepf src/epf/МояВнешняяОбработка build %*
@rem call vrunner compileepf src/erf/МойВнешнийОтчет build %*

@rem собрать расширения конфигурации внутри ИБ
@rem call vrunner compileext src/cfe/МоеРасширение МоеРасширение %*
