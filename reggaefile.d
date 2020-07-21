import reggae;

enum commonFlags = "-w -g";

mixin build!(dubDefaultTarget!(CompilerFlags(commonFlags)),
             dubTestTarget!(CompilerFlags(commonFlags)));
