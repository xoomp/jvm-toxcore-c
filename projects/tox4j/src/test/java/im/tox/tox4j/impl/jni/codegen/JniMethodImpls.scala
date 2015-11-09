package im.tox.tox4j.impl.jni.codegen

import im.tox.tox4j.av.ToxAv
import im.tox.tox4j.core.ToxCore
import im.tox.tox4j.impl.jni.codegen.NameConversions.cxxVarName
import im.tox.tox4j.impl.jni.codegen.cxx.Ast._
import im.tox.tox4j.impl.jni.{AutoGenerated, MethodMap, ToxAvJni, ToxCoreJni}

import scala.reflect.runtime.{universe => u}

object JniMethodImpls extends CodeGenerator {

  val javaTypeMap = Map(
    "void" -> Type.void,
    "int" -> Type.jint,
    "boolean" -> Type.jboolean
  )

  val scalaTypeMap = Map(
    "Int" -> Type.jint
  )

  def cxxType(typeSignature: u.Type): Type = {
    scalaTypeMap(typeSignature.toString)
  }

  def cxxParams(params: Seq[(u.Type, u.Name)]): Seq[Param] = {
    params map {
      case (typeSignature, name) =>
        Param(cxxType(typeSignature), name.toString)
    }
  }

  def generateNativeCode[T](jniClass: Class[_])(implicit evidence: u.TypeTag[T]): TranslationUnit = {
    val mirror = u.runtimeMirror(jniClass.getClassLoader)
    val traitMirror = mirror.typeOf[T]

    MethodMap(jniClass).toSeq filter {
      case (name, method) =>
        method.getAnnotation(classOf[AutoGenerated]) != null
    } map {
      case (name, method) =>
        val params = traitMirror
          .member(u.TermName(name)).asMethod
          .paramLists.flatten
          .map { sym => (sym.typeSignature, sym.name) }

        ToxFun(
          returnType = javaTypeMap(method.getReturnType.getName),
          name = method.getName,
          params = Param(Type.jint, "instanceNumber") +: cxxParams(params),
          body = CompoundStmt(
            Return(FunCall(
              Access(Identifier("instances"), "with_instance_noerr"),
              Seq(
                Identifier("env"),
                Identifier("instanceNumber"),
                Identifier(cxxVarName(method.getName))
              ) ++ cxxParams(params).map(_.name).map(Identifier)
            ))
          )
        )
    }
  }

  writeCode("ToxAv/generated/impls.h") {
    Comment(classOf[ToxAvJni].getName) +:
      generateNativeCode[ToxAv[_]](classOf[ToxAvJni])
  }

  writeCode("ToxCore/generated/impls.h") {
    Comment(classOf[ToxCoreJni].getName) +:
      generateNativeCode[ToxCore[_]](classOf[ToxCoreJni])
  }

}
